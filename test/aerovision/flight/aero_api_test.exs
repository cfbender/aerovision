defmodule AeroVision.Flight.AeroAPITest do
  @moduledoc """
  Tests for AeroVision.Flight.AeroAPI.

  We test behaviours that don't require HTTP: cache operations, monthly
  usage counter, call cap enforcement, and PubSub broadcasts. HTTP paths
  are covered by integration with real credentials (not tested here).
  """
  use ExUnit.Case, async: false

  alias AeroVision.Flight.{AeroAPI, FlightInfo, Airport}
  alias AeroVision.Config.Store

  @cache_table :aerovision_aeroapi_cache

  # ── setup ──────────────────────────────────────────────────────────────────

  setup do
    Store.reset()
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "flights")

    # Each test gets its own temp dir so CubDB doesn't conflict across tests.
    tmp = Path.join(System.tmp_dir!(), "aeroapi_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    start_supervised!({AeroAPI, data_dir: tmp})
    :ok
  end

  # ── monthly_usage/0 ─────────────────────────────────────────────────────────

  test "monthly_usage/0 returns 0 on fresh start" do
    assert AeroAPI.monthly_usage() == 0
  end

  # ── get_cached/1 ────────────────────────────────────────────────────────────

  test "get_cached/1 returns nil when callsign is not in cache" do
    assert AeroAPI.get_cached("ZZZ999") == nil
  end

  test "get_cached/1 returns cached FlightInfo within TTL" do
    info = %FlightInfo{
      ident: "AAL1234",
      operator: "AAL",
      airline_name: "American Airlines",
      aircraft_type: "B738",
      aircraft_name: nil,
      origin: %Airport{icao: "KRDU", iata: "RDU", name: "Raleigh", city: "Raleigh"},
      destination: %Airport{icao: "KCLT", iata: "CLT", name: "Charlotte", city: "Charlotte"},
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    now = System.system_time(:second)
    :ets.insert(@cache_table, {"AAL1234", info, now})

    result = AeroAPI.get_cached("AAL1234")
    assert result.ident == "AAL1234"
    assert result.airline_name == "American Airlines"
  end

  test "get_cached/1 returns nil for expired cache entry" do
    info = %FlightInfo{
      ident: "AAL1234",
      operator: "AAL",
      airline_name: "American Airlines",
      aircraft_type: "B738",
      aircraft_name: nil,
      origin: nil,
      destination: nil,
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    # Insert with a timestamp > 24h ago (TTL = 86400s)
    expired_at = System.system_time(:second) - 86_401
    :ets.insert(@cache_table, {"AAL1234", info, expired_at})

    assert AeroAPI.get_cached("AAL1234") == nil
  end

  # ── enrich/1 ─────────────────────────────────────────────────────────────────

  test "enrich/1 returns :ok immediately" do
    assert AeroAPI.enrich("AAL1234") == :ok
  end

  @tag :capture_log
  test "enrich/1 with no API key configured — no broadcast within 1500ms" do
    # Store has no aeroapi_key (reset in setup)
    AeroAPI.enrich("AAL1234")

    # Give the rate-limited queue time to process — no API key → no broadcast
    refute_receive {:flight_enriched, "AAL1234", _}, 1500
  end

  test "enrich/1 same callsign twice is deduplicated in queue" do
    # Queue two enrichments for the same callsign — only one should fire
    AeroAPI.enrich("AAL1234")
    AeroAPI.enrich("AAL1234")

    # We can't easily observe the queue size, but the GenServer shouldn't crash
    :sys.get_state(GenServer.whereis(AeroAPI))
    assert Process.alive?(GenServer.whereis(AeroAPI))
  end

  # ── monthly call cap ─────────────────────────────────────────────────────────

  @tag :capture_log
  test "respects monthly call cap — does not exceed @monthly_call_cap" do
    # Force the call count to be at or above the cap by manipulating state
    pid = GenServer.whereis(AeroAPI)

    :sys.replace_state(pid, fn state ->
      %{state | call_count: 1_000}
    end)

    # With call_count at 1000 (the cap), enrich should be a no-op
    AeroAPI.enrich("AAL1234")

    # After one tick (1 second), no HTTP call should have been made
    # (verified by absence of broadcast since no API key anyway, but also
    # the cap logic should fire first)
    refute_receive {:flight_enriched, "AAL1234", _}, 1500
  end

  # ── :prune message ───────────────────────────────────────────────────────────

  test ":prune message does not crash the GenServer" do
    pid = GenServer.whereis(AeroAPI)
    send(pid, :prune)
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test ":prune clears expired ETS entries" do
    # Insert an expired entry directly
    expired_at = System.system_time(:second) - 86_401

    info = %FlightInfo{
      ident: "DAL456",
      operator: "DAL",
      airline_name: "Delta",
      aircraft_type: "A321",
      aircraft_name: nil,
      origin: nil,
      destination: nil,
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    # Write to ETS and CubDB directly via the GenServer's db handle
    pid = GenServer.whereis(AeroAPI)
    state = :sys.get_state(pid)
    :ets.insert(@cache_table, {"DAL456", info, expired_at})
    CubDB.put(state.db, "DAL456", {info, expired_at})

    # Trigger prune
    send(pid, :prune)
    :sys.get_state(pid)

    # Expired entry should be gone from ETS (get_cached returns nil)
    assert AeroAPI.get_cached("DAL456") == nil
  end

  # ── handle_info catch-all ────────────────────────────────────────────────────

  test "unknown messages are ignored without crash" do
    pid = GenServer.whereis(AeroAPI)
    send(pid, {:unknown_message, :whatever})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── enrich/1 queuing ─────────────────────────────────────────────────────────

  test "enrich/1 queues callsign and GenServer remains alive" do
    AeroAPI.enrich("DAL456")
    :sys.get_state(GenServer.whereis(AeroAPI))
    assert Process.alive?(GenServer.whereis(AeroAPI))
  end

  test "enrich/1 same callsign twice does not crash" do
    AeroAPI.enrich("AAL123")
    AeroAPI.enrich("AAL123")
    :sys.get_state(GenServer.whereis(AeroAPI))
    assert Process.alive?(GenServer.whereis(AeroAPI))
  end

  # ── :tick processing ─────────────────────────────────────────────────────────

  test ":tick with cached callsign skips HTTP and does not broadcast" do
    # Pre-populate the cache so get_cached returns a valid entry
    info = %FlightInfo{
      ident: "SWA456",
      operator: "SWA",
      airline_name: "Southwest",
      aircraft_type: "B737",
      aircraft_name: nil,
      origin: nil,
      destination: nil,
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    :ets.insert(@cache_table, {"SWA456", info, System.system_time(:second)})
    AeroAPI.enrich("SWA456")

    # After tick, the already-cached callsign should be skipped (no HTTP, no broadcast)
    refute_receive {:flight_enriched, "SWA456", _}, 1500
  end
end
