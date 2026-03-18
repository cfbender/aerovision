defmodule AeroVision.Flight.TrackerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias AeroVision.Config.Store
  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Skylink.FlightStatus
  alias AeroVision.Flight.StateVector
  alias AeroVision.Flight.TrackedFlight
  alias AeroVision.Flight.Tracker

  # ── helpers ────────────────────────────────────────────────────────────────

  defp sv(callsign, opts \\ []) do
    %StateVector{
      icao24: Keyword.get(opts, :icao24, "abc123"),
      callsign: callsign,
      origin_country: "USA",
      longitude: Keyword.get(opts, :lon, -78.6),
      latitude: Keyword.get(opts, :lat, 35.8),
      baro_altitude: Keyword.get(opts, :alt, 10_000.0),
      on_ground: Keyword.get(opts, :on_ground, false),
      velocity: 200.0,
      true_track: 90.0,
      vertical_rate: 0.0,
      geo_altitude: 10_000.0,
      squawk: nil,
      last_contact: System.system_time(:second),
      time_position: System.system_time(:second),
      position_source: 0
    }
  end

  defp fi(opts \\ []) do
    now = DateTime.utc_now()
    dep = Keyword.get(opts, :dep, DateTime.add(now, -3600))
    arr = Keyword.get(opts, :arr, DateTime.add(now, 3600))

    %FlightInfo{
      ident: Keyword.get(opts, :ident, "AAL1234"),
      operator: "AAL",
      airline_name: "American Airlines",
      aircraft_type: "B738",
      aircraft_name: nil,
      origin: %Airport{icao: "KRDU", iata: "RDU", name: "Raleigh-Durham", city: "Raleigh"},
      destination: %Airport{icao: "KCLT", iata: "CLT", name: "Charlotte", city: "Charlotte"},
      departure_time: dep,
      actual_departure_time: nil,
      arrival_time: arr,
      status: nil,
      progress_pct: nil,
      cached_at: now
    }
  end

  defp broadcast_raw(vectors) do
    Phoenix.PubSub.broadcast(AeroVision.PubSub, "flights", {:flights_raw, vectors})
  end

  defp broadcast_enriched(callsign, info) do
    Phoenix.PubSub.broadcast(AeroVision.PubSub, "flights", {:flight_enriched, callsign, info})
  end

  defp broadcast_config(key, value) do
    Phoenix.PubSub.broadcast(AeroVision.PubSub, "config", {:config_changed, key, value})
  end

  # Drain the initial broadcast fired by handle_continue(:broadcast_initial)
  defp drain_initial_broadcast do
    receive do
      {:display_flights, _} -> :ok
    after
      50 -> :ok
    end
  end

  # Flush all remaining messages from the test process mailbox.
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ── setup ──────────────────────────────────────────────────────────────────

  setup do
    Store.reset()

    # Give the Tracker its own temp dir so it uses a real (but isolated) CubDB.
    # This avoids global CubDB stubs that would contend with Config.Store's
    # CubDB calls in other concurrently-running test files.
    tmp_dir = Path.join(System.tmp_dir!(), "tracker_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Stub FlightStatus functions (private to this test process) so no HTTP happens.
    # Tests inject enrichment results directly via broadcast_enriched/2.
    stub(FlightStatus, :enrich, fn _callsign -> :ok end)
    stub(FlightStatus, :needs_refresh?, fn _callsign -> false end)
    stub(FlightStatus, :re_enrich, fn _callsign -> :ok end)

    # Ensure the ETS cache table exists for FlightStatus.get_cached/1.
    cache_table = :aerovision_skylink_cache

    case :ets.whereis(cache_table) do
      :undefined ->
        :ets.new(cache_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ets.delete_all_objects(cache_table)
    end

    # Extend the FlightStatus stubs to the Tracker process after it starts.
    start_supervised!({Tracker, data_dir: tmp_dir})
    tracker_pid = GenServer.whereis(Tracker)
    allow(FlightStatus, self(), tracker_pid)

    Phoenix.PubSub.subscribe(AeroVision.PubSub, "display")
    drain_initial_broadcast()
    flush_mailbox()
    :ok
  end

  # ── get_flights/0 ──────────────────────────────────────────────────────────

  test "get_flights/0 initially returns []" do
    assert Tracker.get_flights() == []
  end

  # ── {:flights_raw, vectors} ────────────────────────────────────────────────

  test "new callsign creates TrackedFlight — get_flights/0 returns it" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, flights}
    assert length(flights) == 1
    assert hd(flights).state_vector.callsign == "AAL1234"
  end

  test "two different callsigns both appear in get_flights/0" do
    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, flights}
    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
    assert "DAL567" in callsigns
  end

  test "nil callsign is ignored" do
    broadcast_raw([sv(nil)])
    assert_receive {:display_flights, flights}
    assert flights == []
  end

  test "known callsign updates state_vector on subsequent broadcast" do
    broadcast_raw([sv("AAL1234", lon: -78.6)])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234", lon: -79.0)])
    assert_receive {:display_flights, flights}

    [flight] = flights
    assert flight.state_vector.longitude == -79.0
  end

  test "known callsign preserves flight_info after update" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL1234", fi())
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234", alt: 20_000.0)])
    assert_receive {:display_flights, flights}

    [flight] = flights
    assert flight.state_vector.baro_altitude == 20_000.0
    assert flight.flight_info
    assert flight.flight_info.ident == "AAL1234"
  end

  test "raw flights broadcast triggers {:display_flights, flights} on 'display' topic" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, [_flight]}
  end

  test "on_ground flights are still tracked" do
    broadcast_raw([sv("AAL1234", on_ground: true)])
    assert_receive {:display_flights, flights}
    assert length(flights) == 1
    assert hd(flights).state_vector.on_ground == true
  end

  # ── {:flight_enriched, callsign, info} ─────────────────────────────────────

  test "enrichment updates tracked flight's flight_info field" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL1234", fi())
    assert_receive {:display_flights, flights}

    [flight] = flights
    assert flight.flight_info
    assert flight.flight_info.airline_name == "American Airlines"
  end

  test "enrichment calculates and sets progress_pct" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    # departed 30 min ago, arrives in 30 min — expect ~50% progress
    now = DateTime.utc_now()
    info = fi(dep: DateTime.add(now, -1800), arr: DateTime.add(now, 1800))
    broadcast_enriched("AAL1234", info)
    assert_receive {:display_flights, flights}

    [flight] = flights
    assert flight.flight_info.progress_pct
    assert_in_delta flight.flight_info.progress_pct, 0.5, 0.05
  end

  test "enrichment for unknown callsign is ignored — no crash" do
    broadcast_enriched("UNKNOWN1", fi())
    assert Tracker.get_flights() == []
    refute_receive {:display_flights, _}, 100
  end

  test "enrichment triggers {:display_flights, flights} broadcast" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL1234", fi())
    assert_receive {:display_flights, flights}
    assert length(flights) == 1
  end

  test "progress_pct is nil when arrival_time is nil" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL1234", %{fi() | arrival_time: nil})
    assert_receive {:display_flights, flights}

    [flight] = flights
    assert is_nil(flight.flight_info.progress_pct)
  end

  test "progress_pct is nil when departure is in the future" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    now = DateTime.utc_now()
    info = fi(dep: DateTime.add(now, 3600), arr: DateTime.add(now, 7200))
    broadcast_enriched("AAL1234", info)
    assert_receive {:display_flights, flights}

    [flight] = flights
    assert is_nil(flight.flight_info.progress_pct)
  end

  # ── get_flight/1 ───────────────────────────────────────────────────────────

  test "get_flight/1 returns tracked flight for known callsign" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    flight = Tracker.get_flight("AAL1234")
    assert %TrackedFlight{} = flight
    assert flight.state_vector.callsign == "AAL1234"
  end

  test "get_flight/1 returns nil for unknown callsign" do
    assert Tracker.get_flight("ZZZ9999") == nil
  end

  # ── broadcast_now ──────────────────────────────────────────────────────────

  test "broadcast_now triggers {:display_flights, []} initially" do
    Tracker.broadcast_now()
    assert_receive {:display_flights, []}
  end

  test "broadcast_now triggers broadcast with current flights" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    Tracker.broadcast_now()
    assert_receive {:display_flights, flights}
    assert length(flights) == 1
  end

  # ── :cleanup ───────────────────────────────────────────────────────────────

  test ":cleanup does not prune fresh flights" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, [_]}

    pid = GenServer.whereis(Tracker)
    send(pid, :cleanup)
    _ = :sys.get_state(pid)

    assert length(Tracker.get_flights()) == 1
  end

  test ":cleanup removes genuinely stale flights" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, [_flight]}

    pid = GenServer.whereis(Tracker)

    # Back-date the flight's last_seen_at to 200s ago
    :sys.replace_state(pid, fn state ->
      stale_time = DateTime.add(DateTime.utc_now(), -200, :second)

      updated_flights =
        Map.update(state.flights, "AAL1234", nil, fn tracked ->
          %{tracked | last_seen_at: stale_time}
        end)

      %{state | flights: updated_flights}
    end)

    send(pid, :cleanup)
    _ = :sys.get_state(pid)

    assert Tracker.get_flights() == []
  end

  # ── filtering: mode :nearby ────────────────────────────────────────────────

  test "nearby mode with no airline_filters returns all flights (up to 3)" do
    broadcast_raw([sv("AAL1234"), sv("DAL567"), sv("UAL890")])
    assert_receive {:display_flights, flights}
    assert length(flights) == 3
  end

  test "nearby mode limits to @max_display_flights (3)" do
    broadcast_raw([sv("AAL001"), sv("AAL002"), sv("AAL003"), sv("AAL004"), sv("AAL005")])
    assert_receive {:display_flights, flights}
    assert length(flights) == 3
  end

  test "nearby mode with airline_filters only shows matching callsigns" do
    broadcast_config(:airline_filters, ["AAL"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
    refute "DAL567" in callsigns
  end

  test "nearby mode with airline_filters excludes non-matching prefix" do
    broadcast_config(:airline_filters, ["AAL"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("DAL123")])
    assert_receive {:display_flights, flights}
    assert flights == []
  end

  test "nearby mode with multiple airline_filters includes all matching airlines" do
    broadcast_config(:airline_filters, ["AAL", "DAL"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234"), sv("DAL567"), sv("UAL890")])
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
    assert "DAL567" in callsigns
    refute "UAL890" in callsigns
  end

  # ── filtering: mode :tracked ───────────────────────────────────────────────

  test "tracked mode only returns exact callsign matches" do
    broadcast_config(:display_mode, :tracked)
    assert_receive {:display_flights, _}
    broadcast_config(:tracked_flights, ["AAL1234"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
    refute "DAL567" in callsigns
  end

  test "tracked mode with empty tracked_flights shows no flights" do
    broadcast_config(:display_mode, :tracked)
    assert_receive {:display_flights, _}
    broadcast_config(:tracked_flights, [])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, flights}
    assert flights == []
  end

  test "tracked mode is case-insensitive" do
    broadcast_config(:display_mode, :tracked)
    assert_receive {:display_flights, _}
    broadcast_config(:tracked_flights, ["aal1234"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, flights}
    assert length(flights) == 1
    assert hd(flights).state_vector.callsign == "AAL1234"
  end

  # ── top_flights ordering ───────────────────────────────────────────────────

  test "enriched flights are prioritized over unenriched in top_flights" do
    broadcast_raw([sv("AAL001"), sv("AAL002"), sv("AAL003"), sv("AAL004")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL004", fi(ident: "AAL004"))
    assert_receive {:display_flights, flights}

    assert hd(flights).state_vector.callsign == "AAL004"
  end

  # ── config_changed messages ─────────────────────────────────────────────────

  test "{:config_changed, :display_mode, :tracked} updates mode and broadcasts" do
    broadcast_config(:display_mode, :tracked)
    assert_receive {:display_flights, _}
    broadcast_config(:tracked_flights, [])
    assert_receive {:display_flights, _}
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, flights}
    assert flights == []
  end

  test "{:config_changed, :location_lat, ...} clears all flights and broadcasts []" do
    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, flights}
    assert length(flights) == 2

    broadcast_config(:location_lat, 40.0)
    assert_receive {:display_flights, []}
    assert Tracker.get_flights() == []
  end

  test "{:config_changed, :location_lon, ...} also clears flights" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, [_]}

    broadcast_config(:location_lon, -95.0)
    assert_receive {:display_flights, []}
  end

  test "{:config_changed, :radius_km, ...} also clears flights" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, [_]}

    broadcast_config(:radius_km, 25)
    assert_receive {:display_flights, []}
  end

  test "{:config_changed, :airline_filters, ...} updates filters and broadcasts" do
    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, _}

    broadcast_config(:airline_filters, ["DAL"])
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    refute "AAL1234" in callsigns
    assert "DAL567" in callsigns
  end

  test "{:config_changed, :tracked_flights, ...} updates list and broadcasts" do
    broadcast_config(:display_mode, :tracked)
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, _}

    broadcast_config(:tracked_flights, ["DAL567"])
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "DAL567" in callsigns
    refute "AAL1234" in callsigns
  end

  test "unrelated config changes are ignored without crash" do
    broadcast_config(:display_brightness, 50)
    refute_receive {:display_flights, _}, 100
  end

  # ── filtering: airport filters ──────────────────────────────────────────────

  defp fi_with_airports(origin_iata, dest_iata) do
    now = DateTime.utc_now()

    %FlightInfo{
      ident: "AAL1234",
      operator: "AAL",
      airline_name: "American Airlines",
      aircraft_type: "B738",
      aircraft_name: nil,
      origin: %Airport{icao: "K" <> origin_iata, iata: origin_iata, name: origin_iata, city: nil},
      destination: %Airport{
        icao: "K" <> dest_iata,
        iata: dest_iata,
        name: dest_iata,
        city: nil
      },
      departure_time: DateTime.add(now, -3600),
      actual_departure_time: nil,
      arrival_time: DateTime.add(now, 3600),
      status: nil,
      progress_pct: nil,
      cached_at: now
    }
  end

  test "airport filter passes unenriched flights (pending enrichment)" do
    broadcast_config(:airport_filters, ["RDU"])
    assert_receive {:display_flights, _}

    # Raw flight with no enrichment yet — should pass airport filter
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
  end

  test "airport filter shows flight departing matching airport after enrichment" do
    broadcast_config(:airport_filters, ["RDU"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    # Enrich with RDU origin
    broadcast_enriched("AAL1234", fi_with_airports("RDU", "LAX"))
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
  end

  test "airport filter shows flight arriving at matching airport after enrichment" do
    broadcast_config(:airport_filters, ["RDU"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("DAL567")])
    assert_receive {:display_flights, _}

    # Enrich with RDU destination
    info = %{fi_with_airports("ATL", "RDU") | ident: "DAL567"}
    broadcast_enriched("DAL567", info)
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "DAL567" in callsigns
  end

  test "airport filter hides enriched flight not matching any airport" do
    broadcast_config(:airport_filters, ["RDU"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("UAL890")])
    assert_receive {:display_flights, _}

    # Enrich with non-RDU airports — should be filtered out
    info = %{fi_with_airports("ORD", "LAX") | ident: "UAL890"}
    broadcast_enriched("UAL890", info)
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    refute "UAL890" in callsigns
  end

  test "airport filter accepts ICAO codes" do
    broadcast_config(:airport_filters, ["KRDU"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL1234", fi_with_airports("RDU", "CLT"))
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
  end

  test "airport filter is case-insensitive" do
    broadcast_config(:airport_filters, ["rdu"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, _}

    broadcast_enriched("AAL1234", fi_with_airports("RDU", "CLT"))
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "AAL1234" in callsigns
  end

  test "airport filter stacks with airline filter — must pass both" do
    # Only DAL flights to/from RDU
    broadcast_config(:airline_filters, ["DAL"])
    assert_receive {:display_flights, _}
    broadcast_config(:airport_filters, ["RDU"])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, _}

    # AAL doesn't match airline filter → excluded even though it goes to RDU
    broadcast_enriched("AAL1234", fi_with_airports("RDU", "CLT"))
    assert_receive {:display_flights, _}

    # DAL to RDU → matches both filters → included
    info_dal = %{fi_with_airports("ATL", "RDU") | ident: "DAL567"}
    broadcast_enriched("DAL567", info_dal)
    assert_receive {:display_flights, flights}

    callsigns = Enum.map(flights, & &1.state_vector.callsign)
    assert "DAL567" in callsigns
    refute "AAL1234" in callsigns
  end

  # ── progress_pct recalculation ─────────────────────────────────────────────

  describe "progress_pct" do
    test "is recalculated on each ADS-B tick, not frozen at enrichment value" do
      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      now = DateTime.utc_now()
      # Enrich: departed 1h ago, arrives in 1h → ~50%
      broadcast_enriched(
        "AAL1234",
        fi(dep: DateTime.add(now, -3600), arr: DateTime.add(now, 3600))
      )

      assert_receive {:display_flights, flights}
      assert_in_delta hd(flights).flight_info.progress_pct, 0.5, 0.05

      # Directly update the stored flight_info to simulate time passing:
      # departure 7000s ago, arrival 200s ago → flight already complete, should cap at 1.0
      pid = GenServer.whereis(Tracker)

      :sys.replace_state(pid, fn state ->
        Map.update!(state, :flights, fn fm ->
          Map.update!(fm, "AAL1234", fn tracked ->
            new_fi = %{
              tracked.flight_info
              | departure_time: DateTime.add(now, -7000),
                arrival_time: DateTime.add(now, -200)
            }

            %{tracked | flight_info: new_fi}
          end)
        end)
      end)

      # Next tick should recalculate — not return the stale ~0.5
      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, flights}
      assert hd(flights).flight_info.progress_pct == 1.0
    end

    test "ignores estimated_arrival within 15 min of departure, falls back to scheduled" do
      broadcast_raw([sv("DAL1068")])
      assert_receive {:display_flights, _}

      now = DateTime.utc_now()
      actual_dep = DateTime.add(now, -5400)
      # API bug: estimated_arrival == actual_departure (diff = 0 < 900s)
      bad_estimated_arr = actual_dep
      scheduled_arr = DateTime.add(now, 1800)

      info = %{
        fi()
        | departure_time: actual_dep,
          actual_departure_time: actual_dep,
          estimated_arrival_time: bad_estimated_arr,
          arrival_time: scheduled_arr
      }

      broadcast_enriched("DAL1068", info)
      assert_receive {:display_flights, flights}
      [flight] = flights

      # bad estimated rejected → uses scheduled arrival
      # 90 min elapsed of 120 min total → ~75%
      assert flight.flight_info.progress_pct
      assert_in_delta flight.flight_info.progress_pct, 0.75, 0.05
    end

    test "tracked synthetic flight progress is recalculated on each ADS-B tick" do
      broadcast_config(:display_mode, :tracked)
      assert_receive {:display_flights, _}
      broadcast_config(:tracked_flights, ["AAL1234"])
      assert_receive {:display_flights, _}

      now = DateTime.utc_now()
      # Enrich in tracked mode (creates synthetic entry via flight_enriched handler)
      broadcast_enriched(
        "AAL1234",
        fi(dep: DateTime.add(now, -3600), arr: DateTime.add(now, 3600))
      )

      assert_receive {:display_flights, flights}
      assert_in_delta hd(flights).flight_info.progress_pct, 0.5, 0.05

      pid = GenServer.whereis(Tracker)

      :sys.replace_state(pid, fn state ->
        Map.update!(state, :flights, fn fm ->
          Map.update!(fm, "AAL1234", fn tracked ->
            new_fi = %{
              tracked.flight_info
              | departure_time: DateTime.add(now, -7000),
                arrival_time: DateTime.add(now, -200)
            }

            %{tracked | flight_info: new_fi}
          end)
        end)
      end)

      # Empty ADS-B tick — inject_missing_tracked runs, should recalculate progress
      broadcast_raw([])
      assert_receive {:display_flights, flights}
      assert hd(flights).flight_info.progress_pct == 1.0
    end
  end

  test "empty airport filter shows all flights" do
    broadcast_config(:airport_filters, [])
    assert_receive {:display_flights, _}

    broadcast_raw([sv("AAL1234"), sv("DAL567")])
    assert_receive {:display_flights, flights}

    assert length(flights) == 2
  end

  test "{:config_changed, :airport_filters, ...} updates filters and broadcasts" do
    broadcast_raw([sv("AAL1234")])
    assert_receive {:display_flights, [_]}

    broadcast_config(:airport_filters, ["RDU"])
    assert_receive {:display_flights, _}
    assert Process.alive?(GenServer.whereis(Tracker))
  end

  # ── enrichment candidate limiting ─────────────────────────────────────────

  describe "enrich_top_candidates" do
    # User location: 35.0°N, -80.0°W
    # Distances (approximate):
    #   FL001 at (35.01, -80.0)  →  ~1 km   (closest)
    #   FL002 at (35.05, -80.0)  →  ~6 km
    #   FL003 at (35.10, -80.0)  →  ~11 km
    #   FL004 at (35.20, -80.0)  →  ~22 km
    #   FL005 at (35.30, -80.0)  →  ~33 km
    #   FL006 at (35.50, -80.0)  →  ~55 km  (outside top-5)
    #   FL007 at (35.70, -80.0)  →  ~78 km  (outside top-5)
    #   FL008 at (36.00, -80.0)  →  ~111 km (outside top-5)
    @enrich_lat 35.0
    @enrich_lon -80.0

    setup do
      pid = GenServer.whereis(Tracker)

      :sys.replace_state(pid, fn state ->
        %{state | location_lat: @enrich_lat, location_lon: @enrich_lon}
      end)

      flush_mailbox()
      :ok
    end

    test "in nearby mode, only top 5 closest flights get enrichment requests" do
      # 8 flights at distinct distances — only the 5 closest should be enriched
      vectors = [
        sv("FL001", lat: 35.01, lon: -80.0),
        sv("FL002", lat: 35.05, lon: -80.0),
        sv("FL003", lat: 35.10, lon: -80.0),
        sv("FL004", lat: 35.20, lon: -80.0),
        sv("FL005", lat: 35.30, lon: -80.0),
        sv("FL006", lat: 35.50, lon: -80.0),
        sv("FL007", lat: 35.70, lon: -80.0),
        sv("FL008", lat: 36.00, lon: -80.0)
      ]

      # Track which callsigns had enrich called
      test_pid = self()

      expect(FlightStatus, :enrich, 5, fn callsign ->
        send(test_pid, {:enrich_called, callsign})
        :ok
      end)

      broadcast_raw(vectors)
      assert_receive {:display_flights, _}

      enriched =
        for _ <- 1..5 do
          receive do
            {:enrich_called, cs} -> cs
          after
            500 -> flunk("expected 5 enrich calls, received fewer")
          end
        end

      # Verify exactly 5 enrich calls and no more
      refute_receive {:enrich_called, _}, 100

      # The 5 closest flights must have been enriched
      assert "FL001" in enriched
      assert "FL002" in enriched
      assert "FL003" in enriched
      assert "FL004" in enriched
      assert "FL005" in enriched

      # The 3 farthest must NOT have been enriched
      refute "FL006" in enriched
      refute "FL007" in enriched
      refute "FL008" in enriched
    end

    test "in nearby mode with airline filters, respects both filter and candidate limit" do
      # 5 DAL + 5 SWA flights — only the 5 closest DAL flights should be enriched
      vectors = [
        sv("DAL001", lat: 35.01, lon: -80.0),
        sv("DAL002", lat: 35.05, lon: -80.0),
        sv("DAL003", lat: 35.10, lon: -80.0),
        sv("SWA001", lat: 35.02, lon: -80.0),
        sv("SWA002", lat: 35.06, lon: -80.0),
        sv("SWA003", lat: 35.11, lon: -80.0),
        sv("DAL004", lat: 35.20, lon: -80.0),
        sv("DAL005", lat: 35.30, lon: -80.0),
        sv("SWA004", lat: 35.21, lon: -80.0),
        sv("SWA005", lat: 35.31, lon: -80.0)
      ]

      broadcast_config(:airline_filters, ["DAL"])
      assert_receive {:display_flights, _}
      flush_mailbox()

      test_pid = self()

      # Only 5 DAL flights exist, all should be enriched (≤ @enrich_candidates limit)
      expect(FlightStatus, :enrich, 5, fn callsign ->
        send(test_pid, {:enrich_called, callsign})
        :ok
      end)

      broadcast_raw(vectors)
      assert_receive {:display_flights, _}

      enriched =
        for _ <- 1..5 do
          receive do
            {:enrich_called, cs} -> cs
          after
            500 -> flunk("expected 5 DAL enrich calls")
          end
        end

      # No more enrich calls
      refute_receive {:enrich_called, _}, 100

      # All enriched callsigns must be DAL (airline filter respected)
      assert Enum.all?(enriched, &String.starts_with?(&1, "DAL"))

      # No SWA flights enriched
      refute Enum.any?(enriched, &String.starts_with?(&1, "SWA"))
    end

    test "in tracked mode, all tracked callsigns get enriched regardless of distance" do
      broadcast_config(:display_mode, :tracked)
      assert_receive {:display_flights, _}
      broadcast_config(:tracked_flights, ["AAL1234", "DAL567", "UAL890"])
      assert_receive {:display_flights, _}
      flush_mailbox()

      test_pid = self()

      # In tracked mode, request_missing_enrichment is used — all 3 unenriched
      # tracked callsigns should get enrichment calls
      expect(FlightStatus, :enrich, 3, fn callsign ->
        send(test_pid, {:enrich_called, callsign})
        :ok
      end)

      # Tracked flights far apart — distance should not matter
      vectors = [
        sv("AAL1234", lat: 35.01, lon: -80.0),
        sv("DAL567", lat: 40.0, lon: -100.0),
        sv("UAL890", lat: 50.0, lon: -120.0)
      ]

      broadcast_raw(vectors)
      assert_receive {:display_flights, _}

      enriched =
        for _ <- 1..3 do
          receive do
            {:enrich_called, cs} -> cs
          after
            500 -> flunk("expected 3 enrich calls in tracked mode")
          end
        end

      refute_receive {:enrich_called, _}, 100

      assert "AAL1234" in enriched
      assert "DAL567" in enriched
      assert "UAL890" in enriched
    end

    test "config change to airline_filters re-evaluates enrichment candidates" do
      # Seed 7 flights, no filters yet — first 5 closest get enriched
      vectors = [
        sv("FL001", lat: 35.01, lon: -80.0),
        sv("FL002", lat: 35.05, lon: -80.0),
        sv("DAL001", lat: 35.03, lon: -80.0),
        sv("DAL002", lat: 35.07, lon: -80.0),
        sv("DAL003", lat: 35.15, lon: -80.0),
        sv("FL006", lat: 35.50, lon: -80.0),
        sv("FL007", lat: 35.70, lon: -80.0)
      ]

      # Use a stub (not expect) to avoid counting during initial seed
      stub(FlightStatus, :enrich, fn _callsign -> :ok end)

      broadcast_raw(vectors)
      assert_receive {:display_flights, _}
      flush_mailbox()

      test_pid = self()

      # After switching to DAL filter, only DAL flights (all 3 are within top-5
      # by distance after filter) should get enrichment
      expect(FlightStatus, :enrich, 3, fn callsign ->
        send(test_pid, {:enrich_called, callsign})
        :ok
      end)

      broadcast_config(:airline_filters, ["DAL"])
      assert_receive {:display_flights, _}

      enriched =
        for _ <- 1..3 do
          receive do
            {:enrich_called, cs} -> cs
          after
            500 -> flunk("expected 3 DAL enrich calls after filter change")
          end
        end

      refute_receive {:enrich_called, _}, 100

      assert Enum.all?(enriched, &String.starts_with?(&1, "DAL"))
    end
  end

  # ── tracked mode: stale flight refresh ────────────────────────────────────

  describe "refresh_stale_tracked" do
    test "in tracked mode, stale En Route flights get re-enrichment requests" do
      broadcast_config(:display_mode, :tracked)
      assert_receive {:display_flights, _}
      broadcast_config(:tracked_flights, ["AAL1234"])
      assert_receive {:display_flights, _}

      # Send raw flight so it appears in state
      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      # Inject enrichment so flight_info is non-nil with an En Route status
      broadcast_enriched("AAL1234", %{fi(ident: "AAL1234") | status: "En Route"})
      assert_receive {:display_flights, _}
      flush_mailbox()

      test_pid = self()

      # Override: needs_refresh? returns true for AAL1234
      stub(FlightStatus, :needs_refresh?, fn _callsign -> true end)

      expect(FlightStatus, :re_enrich, 1, fn callsign ->
        send(test_pid, {:re_enrich_called, callsign})
        :ok
      end)

      # Trigger another ADS-B tick — this calls enrich_top_candidates which
      # calls refresh_stale_tracked → re_enrich for the stale tracked flight
      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      assert_receive {:re_enrich_called, "AAL1234"}, 500
    end

    test "in tracked mode, Landed flights do NOT get re-enrichment" do
      broadcast_config(:display_mode, :tracked)
      assert_receive {:display_flights, _}
      broadcast_config(:tracked_flights, ["AAL1234"])
      assert_receive {:display_flights, _}

      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      # Enrich with a terminal "Landed" status
      broadcast_enriched("AAL1234", %{fi(ident: "AAL1234") | status: "Landed"})
      assert_receive {:display_flights, _}
      flush_mailbox()

      # needs_refresh? returns true but status is terminal — should NOT call re_enrich
      stub(FlightStatus, :needs_refresh?, fn _callsign -> true end)

      test_pid = self()

      stub(FlightStatus, :re_enrich, fn callsign ->
        send(test_pid, {:re_enrich_called, callsign})
        :ok
      end)

      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      refute_receive {:re_enrich_called, _}, 100
    end

    test "in tracked mode, Cancelled flights do NOT get re-enrichment" do
      broadcast_config(:display_mode, :tracked)
      assert_receive {:display_flights, _}
      broadcast_config(:tracked_flights, ["AAL1234"])
      assert_receive {:display_flights, _}

      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      broadcast_enriched("AAL1234", %{fi(ident: "AAL1234") | status: "Cancelled"})
      assert_receive {:display_flights, _}
      flush_mailbox()

      stub(FlightStatus, :needs_refresh?, fn _callsign -> true end)

      test_pid = self()

      stub(FlightStatus, :re_enrich, fn callsign ->
        send(test_pid, {:re_enrich_called, callsign})
        :ok
      end)

      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      refute_receive {:re_enrich_called, _}, 100
    end

    test "in nearby mode, stale flights do NOT get re-enrichment" do
      # Default mode is :nearby — no display_mode config broadcast needed
      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      broadcast_enriched("AAL1234", %{fi(ident: "AAL1234") | status: "En Route"})
      assert_receive {:display_flights, _}
      flush_mailbox()

      stub(FlightStatus, :needs_refresh?, fn _callsign -> true end)

      test_pid = self()

      stub(FlightStatus, :re_enrich, fn callsign ->
        send(test_pid, {:re_enrich_called, callsign})
        :ok
      end)

      broadcast_raw([sv("AAL1234")])
      assert_receive {:display_flights, _}

      refute_receive {:re_enrich_called, _}, 100
    end
  end

  # ── nearby mode: distance-based sorting ────────────────────────────────────

  describe "nearby mode distance sorting" do
    # User location: 35.0°N, -80.0°W (roughly Charlotte, NC)
    # Distances from user are unambiguous and well-separated:
    #   AAL001 at (35.05, -80.05)  → ~6 km  (closest)
    #   DAL002 at (35.20, -80.00)  → ~22 km
    #   UAL003 at (35.45, -80.00)  → ~50 km
    #   SWA004 at (36.00, -80.00)  → ~111 km (farthest)
    @user_lat 35.0
    @user_lon -80.0

    setup do
      Store.put(:location_lat, @user_lat)
      Store.put(:location_lon, @user_lon)

      # Restart the Tracker so it picks up the pre-seeded location from Store
      pid = GenServer.whereis(Tracker)

      :sys.replace_state(pid, fn state ->
        %{state | location_lat: @user_lat, location_lon: @user_lon}
      end)

      flush_mailbox()
      :ok
    end

    test "flights are returned sorted by distance, closest first" do
      # Send flights out of order (farthest first) to verify sorting
      vectors = [
        sv("SWA004", lat: 36.00, lon: -80.0),
        sv("UAL003", lat: 35.45, lon: -80.0),
        sv("AAL001", lat: 35.05, lon: -80.05),
        sv("DAL002", lat: 35.20, lon: -80.0)
      ]

      broadcast_raw(vectors)
      assert_receive {:display_flights, flights}

      # Only 3 returned (max_display_flights)
      assert length(flights) == 3

      callsigns = Enum.map(flights, & &1.state_vector.callsign)
      # Closest three: AAL001 (~6km), DAL002 (~22km), UAL003 (~50km)
      assert callsigns == ["AAL001", "DAL002", "UAL003"]
      # Farthest (SWA004 ~111km) must not be in results
      refute "SWA004" in callsigns
    end

    test "flight with no position data sorts after positioned flights" do
      vectors = [
        sv("UAL003", lat: 35.45, lon: -80.0),
        # No lat/lon — should sort last
        sv("NOPOS1", lat: nil, lon: nil),
        sv("AAL001", lat: 35.05, lon: -80.05)
      ]

      broadcast_raw(vectors)
      assert_receive {:display_flights, flights}

      assert length(flights) == 3
      callsigns = Enum.map(flights, & &1.state_vector.callsign)
      # Positioned flights come before the no-position flight
      assert List.last(callsigns) == "NOPOS1"
    end

    test "location change refreshes stored lat/lon and clears flights" do
      broadcast_raw([sv("AAL001", lat: 35.05, lon: -80.05)])
      assert_receive {:display_flights, [_]}

      # Change location — flights should be cleared and new coords stored
      Store.put(:location_lat, 40.0)
      broadcast_config(:location_lat, 40.0)
      assert_receive {:display_flights, []}

      pid = GenServer.whereis(Tracker)
      state = :sys.get_state(pid)
      assert state.location_lat == 40.0
    end

    test "when location is nil, falls back to recency-based sort without crash" do
      pid = GenServer.whereis(Tracker)

      :sys.replace_state(pid, fn state ->
        %{state | location_lat: nil, location_lon: nil}
      end)

      flush_mailbox()

      broadcast_raw([sv("AAL001", lat: 35.05, lon: -80.05), sv("DAL002", lat: 35.20, lon: -80.0)])
      assert_receive {:display_flights, flights}
      # Both flights returned (no crash), sorted by recency
      assert length(flights) == 2
    end
  end
end
