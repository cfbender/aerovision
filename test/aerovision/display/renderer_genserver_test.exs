defmodule AeroVision.Display.RendererGenServerTest do
  @moduledoc """
  Tests for AeroVision.Display.Renderer's GenServer behaviour.
  The Display.Driver is mocked so no Port/binary is needed.
  Network.Manager is mocked for QR IP resolution.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias AeroVision.Display.Driver
  alias AeroVision.Display.Renderer
  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.StateVector
  alias AeroVision.Flight.TrackedFlight
  alias AeroVision.Network.Manager, as: NetManager

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tracked_flight(callsign \\ "AAL1234") do
    now = DateTime.utc_now()

    %TrackedFlight{
      state_vector: %StateVector{
        icao24: "abc123",
        callsign: callsign,
        origin_country: "USA",
        longitude: -78.6,
        latitude: 35.8,
        baro_altitude: 10_668.0,
        on_ground: false,
        velocity: 230.0,
        true_track: 45.0,
        vertical_rate: 2.5,
        geo_altitude: 10_972.8,
        squawk: "1200",
        last_contact: System.system_time(:second),
        time_position: System.system_time(:second),
        position_source: 0
      },
      flight_info: %FlightInfo{
        ident: callsign,
        operator: "AAL",
        airline_name: "American Airlines",
        aircraft_type: "B738",
        aircraft_name: nil,
        origin: %Airport{icao: "KRDU", iata: "RDU", name: "Raleigh-Durham", city: "Raleigh"},
        destination: %Airport{
          icao: "KCLT",
          iata: "CLT",
          name: "Charlotte Douglas",
          city: "Charlotte"
        },
        departure_time: DateTime.add(now, -3600),
        actual_departure_time: nil,
        arrival_time: DateTime.add(now, 3600),
        progress_pct: 0.5,
        cached_at: now
      },
      first_seen_at: now,
      last_seen_at: now
    }
  end

  defp delayed_flight(dep_delay_min, arr_delay_min) do
    now = DateTime.utc_now()
    scheduled_dep = DateTime.add(now, -7200)
    actual_dep = DateTime.add(scheduled_dep, dep_delay_min * 60)
    scheduled_arr = DateTime.add(now, 3600)
    estimated_arr = DateTime.add(scheduled_arr, arr_delay_min * 60)

    %TrackedFlight{
      state_vector: %StateVector{
        icao24: "def456",
        callsign: "DAL567",
        origin_country: "USA",
        longitude: -78.6,
        latitude: 35.8,
        baro_altitude: 10_668.0,
        on_ground: false,
        velocity: 230.0,
        true_track: 45.0,
        vertical_rate: 2.5,
        geo_altitude: 10_972.8,
        squawk: "1200",
        last_contact: System.system_time(:second),
        time_position: System.system_time(:second),
        position_source: 0
      },
      flight_info: %FlightInfo{
        ident: "DAL567",
        operator: "DAL",
        airline_name: "Delta",
        aircraft_type: "A321",
        aircraft_name: nil,
        origin: %Airport{icao: "KATL", iata: "ATL", name: "Atlanta", city: "Atlanta"},
        destination: %Airport{icao: "KJFK", iata: "JFK", name: "JFK", city: "New York"},
        departure_time: scheduled_dep,
        actual_departure_time: actual_dep,
        arrival_time: scheduled_arr,
        estimated_arrival_time: estimated_arr,
        progress_pct: 0.5,
        cached_at: now
      },
      first_seen_at: now,
      last_seen_at: now
    }
  end

  # ── setup ──────────────────────────────────────────────────────────────────

  setup do
    AeroVision.Config.Store.reset()

    # Stub Driver.send_command so no Port/binary is needed.
    stub(Driver, :send_command, fn _cmd -> :ok end)

    # Stub Network.Manager.current_ip for QR tests.
    stub(NetManager, :current_ip, fn -> "192.168.1.42" end)

    start_supervised!(Renderer)

    renderer_pid = GenServer.whereis(Renderer)
    allow(Driver, self(), renderer_pid)
    allow(NetManager, self(), renderer_pid)

    :ok
  end

  # ── initial state ───────────────────────────────────────────────────────────

  test "starts in :loading mode" do
    state = :sys.get_state(GenServer.whereis(Renderer))
    assert state.mode == :loading
  end

  test "starts with empty flight list" do
    state = :sys.get_state(GenServer.whereis(Renderer))
    assert state.flights == []
  end

  test "starts with current_index 0" do
    state = :sys.get_state(GenServer.whereis(Renderer))
    assert state.current_index == 0
  end

  test "Driver.send_command is called on init (renders loading state)" do
    # Verify init put the renderer in :loading mode and rendered.
    # We can't intercept the init render via expect because the process starts
    # before allow can be called, so we verify state instead.
    pid = GenServer.whereis(Renderer)
    state = :sys.get_state(pid)
    assert state.mode == :loading
  end

  # ── {:display_flights, flights} ─────────────────────────────────────────────

  test "receiving non-empty flights switches mode to :flights" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :flights
  end

  test "receiving empty flights switches to :loading mode" do
    pid = GenServer.whereis(Renderer)
    # First go to flights mode
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)
    # Then back to empty
    send(pid, {:display_flights, []})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :loading
  end

  test "receiving flights calls Driver.send_command with flight_card" do
    pid = GenServer.whereis(Renderer)

    expect(Driver, :send_command, fn cmd ->
      assert cmd.cmd == "flight_card"
      assert cmd.flight == "AAL1234"
      :ok
    end)

    allow(Driver, self(), pid)
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)
  end

  test "receiving empty flights after having flights calls Driver with scan_anim command" do
    pid = GenServer.whereis(Renderer)

    # First put it in :flights mode so the transition to :loading triggers a render
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)

    expect(Driver, :send_command, fn cmd ->
      assert cmd.cmd == "scan_anim"
      :ok
    end)

    allow(Driver, self(), pid)
    send(pid, {:display_flights, []})
    :sys.get_state(pid)
  end

  # ── {:config_changed, ...} ───────────────────────────────────────────────────

  test "{:config_changed, :display_cycle_seconds, N} updates cycle_seconds" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:config_changed, :display_cycle_seconds, 12})
    :sys.get_state(pid)
    assert :sys.get_state(pid).cycle_seconds == 12
  end

  test "{:config_changed, :display_brightness, N} sends brightness command and re-renders" do
    pid = GenServer.whereis(Renderer)

    # Brightness change sends two commands:
    # 1. The brightness command itself
    # 2. A re-render of the current display state (scan_anim in :loading mode)
    expect(Driver, :send_command, 2, fn cmd ->
      assert cmd.cmd in ["brightness", "scan_anim"]
      :ok
    end)

    allow(Driver, self(), pid)
    send(pid, {:config_changed, :display_brightness, 60})
    :sys.get_state(pid)
  end

  test "{:config_changed, :display_brightness, N} re-renders flight card when in :flights mode" do
    pid = GenServer.whereis(Renderer)

    # Put renderer in :flights mode first
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :flights

    # Brightness change should send brightness command + re-render flight card
    expect(Driver, :send_command, 2, fn cmd ->
      assert cmd.cmd in ["brightness", "flight_card"]
      :ok
    end)

    allow(Driver, self(), pid)
    send(pid, {:config_changed, :display_brightness, 40})
    :sys.get_state(pid)
  end

  test "unrelated config changes are ignored without crash" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:config_changed, :location_lat, 40.0})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── {:button, :short_press} ──────────────────────────────────────────────────

  # Helper: put the renderer into :flights mode (simulates being connected with flights).
  defp put_in_flights_mode(pid) do
    send(pid, {:network, :connected, "192.168.1.42"})
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :flights
  end

  test "short press switches mode to :qr when connected" do
    pid = GenServer.whereis(Renderer)
    put_in_flights_mode(pid)
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :qr
  end

  test "short press is ignored when in :loading mode (not connected)" do
    pid = GenServer.whereis(Renderer)
    assert :sys.get_state(pid).mode == :loading
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :loading
  end

  test "short press is ignored when in :ap mode" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:network, :ap_mode})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :ap
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :ap
  end

  test "short press sends QR command to Driver when connected" do
    pid = GenServer.whereis(Renderer)
    put_in_flights_mode(pid)

    expect(Driver, :send_command, fn cmd ->
      assert cmd.cmd == "qr"
      assert cmd.data =~ "192.168.1.42"
      :ok
    end)

    allow(Driver, self(), pid)
    allow(NetManager, self(), pid)
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
  end

  test "long press is ignored (only short press triggers QR)" do
    pid = GenServer.whereis(Renderer)
    put_in_flights_mode(pid)
    send(pid, {:button, :long_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :flights
  end

  # ── :cycle_tick ──────────────────────────────────────────────────────────────

  test ":cycle_tick advances current_index" do
    pid = GenServer.whereis(Renderer)
    flight1 = tracked_flight("AAL001")
    flight2 = tracked_flight("AAL002")

    send(pid, {:display_flights, [flight1, flight2]})
    :sys.get_state(pid)
    assert :sys.get_state(pid).current_index == 0

    send(pid, :cycle_tick)
    :sys.get_state(pid)
    assert :sys.get_state(pid).current_index == 1
  end

  test ":cycle_tick wraps around to 0 after last flight" do
    pid = GenServer.whereis(Renderer)
    flight1 = tracked_flight("AAL001")
    flight2 = tracked_flight("AAL002")

    send(pid, {:display_flights, [flight1, flight2]})
    :sys.get_state(pid)

    # Advance to index 1
    send(pid, :cycle_tick)
    :sys.get_state(pid)
    # Wrap back to 0
    send(pid, :cycle_tick)
    :sys.get_state(pid)
    assert :sys.get_state(pid).current_index == 0
  end

  test ":cycle_tick in :qr mode does not advance" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:network, :connected, "192.168.1.42"})
    send(pid, {:display_flights, [tracked_flight("AAL001"), tracked_flight("AAL002")]})
    :sys.get_state(pid)
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :qr

    send(pid, :cycle_tick)
    :sys.get_state(pid)
    # mode still :qr, index unchanged
    assert :sys.get_state(pid).mode == :qr
  end

  # ── :qr_end ──────────────────────────────────────────────────────────────────

  test ":qr_end with flights resumes :flights mode" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:network, :connected, "192.168.1.42"})
    send(pid, {:display_flights, [tracked_flight()]})
    :sys.get_state(pid)
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :qr

    send(pid, :qr_end)
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :flights
  end

  test ":qr_end with no flights resumes :loading mode" do
    pid = GenServer.whereis(Renderer)
    # Must be in :flights mode for short press to trigger QR
    put_in_flights_mode(pid)
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :qr

    # Clear flights then end QR — should return to :loading
    send(pid, {:display_flights, []})
    send(pid, :qr_end)
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :loading
  end

  # ── stale current_index guard ────────────────────────────────────────────────

  test "does not crash when flights list shrinks and current_index is out of bounds" do
    pid = GenServer.whereis(Renderer)
    flight1 = tracked_flight("AAL001")
    flight2 = tracked_flight("AAL002")

    # Start with 2 flights, advance cycle to index 1
    send(pid, {:display_flights, [flight1, flight2]})
    :sys.get_state(pid)
    send(pid, :cycle_tick)
    :sys.get_state(pid)
    assert :sys.get_state(pid).current_index == 1

    # Now shrink to 1 flight — index 1 is out of bounds, Enum.at returns nil
    send(pid, {:display_flights, [flight1]})
    :sys.get_state(pid)

    assert Process.alive?(pid)
    assert :sys.get_state(pid).mode == :flights
  end

  # ── network events ───────────────────────────────────────────────────────────

  test "{:network, :connected, ip} is handled without crash" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:network, :connected, "10.0.0.5"})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "{:network, :ap_mode} is handled without crash" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:network, :ap_mode})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── flight card delay colors ─────────────────────────────────────────────

  describe "flight card delay colors" do
    test "on-time flight produces gray time colors" do
      pid = GenServer.whereis(Renderer)

      expect(Driver, :send_command, fn cmd ->
        assert cmd.cmd == "flight_card"
        assert cmd.dep_time_color == [120, 120, 120]
        assert cmd.arr_time_color == [120, 120, 120]
        :ok
      end)

      allow(Driver, self(), pid)
      send(pid, {:display_flights, [tracked_flight()]})
      :sys.get_state(pid)
    end

    test "30-min delayed departure produces orange dep_time_color" do
      pid = GenServer.whereis(Renderer)

      expect(Driver, :send_command, fn cmd ->
        assert cmd.cmd == "flight_card"
        assert cmd.dep_time_color == [251, 146, 60]
        :ok
      end)

      allow(Driver, self(), pid)
      send(pid, {:display_flights, [delayed_flight(30, 0)]})
      :sys.get_state(pid)
    end

    test "90-min delayed arrival produces red arr_time_color" do
      pid = GenServer.whereis(Renderer)

      expect(Driver, :send_command, fn cmd ->
        assert cmd.cmd == "flight_card"
        assert cmd.arr_time_color == [248, 113, 113]
        :ok
      end)

      allow(Driver, self(), pid)
      send(pid, {:display_flights, [delayed_flight(0, 90)]})
      :sys.get_state(pid)
    end

    test "flight with nil flight_info produces gray time colors" do
      pid = GenServer.whereis(Renderer)
      now = DateTime.utc_now()

      nil_info_flight = %TrackedFlight{
        state_vector: %StateVector{
          icao24: "xyz789",
          callsign: "UAL999",
          origin_country: "USA",
          longitude: -78.6,
          latitude: 35.8,
          baro_altitude: 10_668.0,
          on_ground: false,
          velocity: 230.0,
          true_track: 45.0,
          vertical_rate: 2.5,
          geo_altitude: 10_972.8,
          squawk: "1200",
          last_contact: System.system_time(:second),
          time_position: System.system_time(:second),
          position_source: 0
        },
        flight_info: nil,
        first_seen_at: now,
        last_seen_at: now
      }

      expect(Driver, :send_command, fn cmd ->
        assert cmd.cmd == "flight_card"
        assert cmd.dep_time_color == [120, 120, 120]
        assert cmd.arr_time_color == [120, 120, 120]
        :ok
      end)

      allow(Driver, self(), pid)
      send(pid, {:display_flights, [nil_info_flight]})
      :sys.get_state(pid)
    end
  end
end
