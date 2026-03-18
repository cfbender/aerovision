defmodule AeroVision.Flight.Skylink.FlightStatusTest do
  use ExUnit.Case, async: false
  use Mimic

  alias AeroVision.Config.Store
  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightAware
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightStats
  alias AeroVision.Flight.Skylink.FlightStatus

  @cache_table :aerovision_skylink_cache

  setup do
    Store.reset()
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "flights")
    tmp = Path.join(System.tmp_dir!(), "skylink_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    start_supervised!({FlightStatus, data_dir: tmp})
    :ok
  end

  # Helper: extend Mimic stubs from the test process to the FlightStatus GenServer process.
  defp allow_stubs do
    pid = GenServer.whereis(FlightStatus)
    allow(FlightStats, self(), pid)
    allow(FlightAware, self(), pid)
  end

  # A minimal %FlightInfo{} for use in stub return values.
  defp sample_flight_info(callsign) do
    %FlightInfo{
      ident: callsign,
      operator: "DAL",
      airline_name: "Delta Air Lines",
      aircraft_type: "B738",
      aircraft_name: nil,
      origin: %Airport{icao: "KATL", iata: "ATL", name: "Atlanta", city: "Atlanta"},
      destination: %Airport{icao: "KRDU", iata: "RDU", name: "Raleigh", city: "Raleigh"},
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      estimated_arrival_time: nil,
      estimated_departure_time: nil,
      status: "En Route",
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }
  end

  test "monthly_usage/0 returns 0 on fresh start" do
    assert FlightStatus.monthly_usage() == 0
  end

  test "get_cached/1 returns nil when callsign is not in cache" do
    assert FlightStatus.get_cached("ZZZ999") == nil
  end

  test "get_cached/1 returns cached FlightInfo within TTL" do
    info = %FlightInfo{
      ident: "DAL1192",
      operator: nil,
      airline_name: "Delta Air Lines",
      aircraft_type: nil,
      aircraft_name: nil,
      origin: %Airport{icao: "KATL", iata: nil, name: "Atlanta", city: nil},
      destination: %Airport{icao: "KRDU", iata: nil, name: "Raleigh", city: nil},
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      status: "En Route",
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    now = System.system_time(:second)
    :ets.insert(@cache_table, {"DAL1192", info, now})

    result = FlightStatus.get_cached("DAL1192")
    assert result.ident == "DAL1192"
    assert result.status == "En Route"
  end

  test "enrich/1 returns :ok immediately" do
    assert FlightStatus.enrich("DAL1192") == :ok
  end

  @tag :capture_log
  test "enrich/1 with no Skylink key — FlightAware enrichment still broadcasts" do
    # FlightAware is the primary enrichment source and requires no API key,
    # so a broadcast should arrive even when no Skylink key is configured.
    FlightStatus.enrich("DAL1192")
    assert_receive {:flight_enriched, "DAL1192", _}, 5000
  end

  test "unknown messages are ignored without crash" do
    pid = GenServer.whereis(FlightStatus)
    send(pid, {:unknown_message, :whatever})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "negatively cached callsigns are not re-queued" do
    # Insert a negative cache entry directly
    now = System.system_time(:second)
    :ets.insert(@cache_table, {"UNKNOWN123", :not_found, now})

    # Try to enrich — should be silently skipped
    assert FlightStatus.enrich("UNKNOWN123") == :ok

    # Verify it's not in the queue by checking state
    state = :sys.get_state(FlightStatus)
    refute MapSet.member?(state.queue, "UNKNOWN123")
  end

  test "get_cached/1 returns nil for negatively cached callsigns" do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {"NEGTEST", :not_found, now})

    assert FlightStatus.get_cached("NEGTEST") == nil
  end

  test "clear_cache/0 also clears the processing queue" do
    # Enqueue something
    FlightStatus.enrich("QUEUED123")
    _ = :sys.get_state(FlightStatus)

    # Verify it was queued
    state = :sys.get_state(FlightStatus)
    assert MapSet.member?(state.queue, "QUEUED123")

    # Purge cache
    FlightStatus.clear_cache()

    # Verify queue is now empty
    state = :sys.get_state(FlightStatus)
    assert state.queue == MapSet.new()
  end

  # ── needs_refresh?/1 ──────────────────────────────────────────────────────

  describe "needs_refresh?/1" do
    test "returns false for uncached callsign" do
      refute FlightStatus.needs_refresh?("UNKNOWN")
    end

    test "returns false for recently cached callsign" do
      info = sample_flight_info("DAL1209")
      now = System.system_time(:second)
      :ets.insert(@cache_table, {"DAL1209", info, now})

      refute FlightStatus.needs_refresh?("DAL1209")
    end

    test "returns true for callsign cached > 30 minutes ago" do
      info = sample_flight_info("DAL1209")
      # 1801s ago — just past the 1800s refresh TTL
      cached_at = System.system_time(:second) - 1_801
      :ets.insert(@cache_table, {"DAL1209", info, cached_at})

      assert FlightStatus.needs_refresh?("DAL1209")
    end

    test "returns false for negatively cached callsign" do
      now = System.system_time(:second)
      :ets.insert(@cache_table, {"DAL1209NEG", :not_found, now})

      refute FlightStatus.needs_refresh?("DAL1209NEG")
    end

    test "returns false for expired callsign (> 24h)" do
      info = sample_flight_info("DAL1209")
      # 86401s ago — past the 24h cache TTL
      cached_at = System.system_time(:second) - 86_401
      :ets.insert(@cache_table, {"DAL1209EXP", info, cached_at})

      refute FlightStatus.needs_refresh?("DAL1209EXP")
    end
  end

  # ── re_enrich/1 ───────────────────────────────────────────────────────────

  describe "re_enrich/1" do
    test "re-enriches a previously cached callsign by clearing its ETS entry" do
      info = sample_flight_info("DAL1209")
      now = System.system_time(:second)
      :ets.insert(@cache_table, {"DAL1209", info, now})

      # Confirm it is in cache before re_enrich
      assert FlightStatus.get_cached("DAL1209")

      FlightStatus.re_enrich("DAL1209")

      # Synchronise — wait for the GenServer cast to be processed
      _ = :sys.get_state(FlightStatus)

      # ETS entry should be deleted so get_cached returns nil
      assert :ets.lookup(@cache_table, "DAL1209") == []
      assert FlightStatus.get_cached("DAL1209") == nil
    end
  end

  # ── enrichment pipeline tests ─────────────────────────────────────────────

  @tag :capture_log
  test "FlightAware transient failure → FlightStats succeeds → enrichment broadcast" do
    stub(FlightAware, :fetch, fn _callsign -> {:error, {:http_error, :timeout}} end)
    stub(FlightStats, :fetch, fn callsign -> {:ok, sample_flight_info(callsign)} end)
    allow_stubs()

    FlightStatus.enrich("DAL1192")
    assert_receive {:flight_enriched, "DAL1192", flight_info}, 5000
    assert flight_info.ident == "DAL1192"
    assert flight_info.airline_name == "Delta Air Lines"
  end

  @tag :capture_log
  test "FlightAware :no_bootstrap_data → FlightStats succeeds → enrichment broadcast" do
    # :no_bootstrap_data is a permanent FA failure, but FlightStats should still be tried
    stub(FlightAware, :fetch, fn _callsign -> {:error, :no_bootstrap_data} end)
    stub(FlightStats, :fetch, fn callsign -> {:ok, sample_flight_info(callsign)} end)
    allow_stubs()

    FlightStatus.enrich("DAL1192")
    assert_receive {:flight_enriched, "DAL1192", flight_info}, 5000
    assert flight_info.ident == "DAL1192"
  end

  @tag :capture_log
  test "FlightAware permanent failure + FlightStats permanent failure → negative cache" do
    stub(FlightAware, :fetch, fn _callsign -> {:error, :no_bootstrap_data} end)
    stub(FlightStats, :fetch, fn _callsign -> {:error, :unknown_callsign} end)
    allow_stubs()

    FlightStatus.enrich("UNKWN99")
    # No enrichment broadcast should arrive
    refute_receive {:flight_enriched, "UNKWN99", _}, 3000

    # The callsign should be negatively cached
    now = System.system_time(:second)

    assert match?(
             [{_, :not_found, cached_at}] when now - cached_at < 86_400,
             :ets.lookup(@cache_table, "UNKWN99")
           )
  end

  @tag :capture_log
  test "FlightAware transient failure + FlightStats transient failure → Skylink API attempted" do
    stub(FlightAware, :fetch, fn _callsign -> {:error, {:http_error, :timeout}} end)
    stub(FlightStats, :fetch, fn _callsign -> {:error, {:http_error, :timeout}} end)
    allow_stubs()

    # No Skylink key is configured, so the Skylink step will be a no-op (warning logged).
    # The key assertion is: no crash, no negative cache (transient failure shouldn't negative-cache),
    # and no enrichment broadcast (Skylink not configured so nothing succeeds).
    FlightStatus.enrich("DAL1192")
    refute_receive {:flight_enriched, "DAL1192", _}, 3000

    # Callsign must NOT be negatively cached (both failures were transient)
    refute match?(
             [{_, :not_found, _}],
             :ets.lookup(@cache_table, "DAL1192")
           )
  end

  @tag :capture_log
  test "FlightAware success → FlightStats not called" do
    flight_info = sample_flight_info("DAL1192")
    stub(FlightAware, :fetch, fn _callsign -> {:ok, flight_info} end)

    # Expect FlightStats.fetch to never be called; stub raises if it is
    stub(FlightStats, :fetch, fn _callsign ->
      flunk("FlightStats.fetch should not be called when FlightAware succeeds")
    end)

    allow_stubs()

    FlightStatus.enrich("DAL1192")
    assert_receive {:flight_enriched, "DAL1192", received_info}, 5000
    assert received_info.ident == "DAL1192"
  end
end
