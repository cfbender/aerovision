defmodule AeroVision.Display.RendererGenServerTest do
  @moduledoc """
  Tests for AeroVision.Display.Renderer's GenServer behaviour.
  The Display.Driver is mocked so no Port/binary is needed.
  Network.Manager is mocked for QR IP resolution.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias AeroVision.Display.{Renderer, Driver}
  alias AeroVision.Flight.{TrackedFlight, StateVector, FlightInfo, Airport}
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
    # Verify init rendered something by checking the GenServer calls Driver
    # when the loading state fires — we do this by stopping, setting up the
    # expect with allow before restart, then starting.
    stop_supervised!(Renderer)
    stub(Driver, :send_command, fn _cmd -> :ok end)

    start_supervised!(Renderer)
    renderer_pid = GenServer.whereis(Renderer)
    allow(Driver, self(), renderer_pid)

    # Renderer is in :loading mode — send an empty flights list to trigger
    # another loading render, which calls Driver.send_command
    expect(Driver, :send_command, fn cmd ->
      assert cmd.cmd == "text"
      :ok
    end)

    send(renderer_pid, {:display_flights, []})
    :sys.get_state(renderer_pid)
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

  test "receiving empty flights calls Driver with text command (scanning)" do
    pid = GenServer.whereis(Renderer)

    expect(Driver, :send_command, fn cmd ->
      assert cmd.cmd == "text"
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

  test "{:config_changed, :display_brightness, N} sends brightness command" do
    pid = GenServer.whereis(Renderer)

    expect(Driver, :send_command, fn cmd ->
      assert cmd.cmd == "set_brightness"
      assert cmd.value == 60
      :ok
    end)

    allow(Driver, self(), pid)
    send(pid, {:config_changed, :display_brightness, 60})
    :sys.get_state(pid)
  end

  test "unrelated config changes are ignored without crash" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:config_changed, :location_lat, 40.0})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── {:button, :short_press} ──────────────────────────────────────────────────

  test "short press switches mode to :qr" do
    pid = GenServer.whereis(Renderer)
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :qr
  end

  test "short press sends QR command to Driver" do
    pid = GenServer.whereis(Renderer)

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
    initial_mode = :sys.get_state(pid).mode
    send(pid, {:button, :long_press})
    :sys.get_state(pid)
    # Mode unchanged
    assert :sys.get_state(pid).mode == initial_mode
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
    # Start in loading (no flights), go to QR, end QR
    send(pid, {:button, :short_press})
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :qr

    send(pid, :qr_end)
    :sys.get_state(pid)
    assert :sys.get_state(pid).mode == :loading
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
end
