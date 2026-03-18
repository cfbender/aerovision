defmodule AeroVisionWeb.DashboardLiveTest do
  use AeroVisionWeb.ConnCase, async: false
  use Mimic

  alias AeroVision.Config.Store
  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Skylink.FlightStatus
  alias AeroVision.Flight.StateVector
  alias AeroVision.Flight.TrackedFlight
  alias AeroVision.Flight.Tracker
  alias AeroVision.Network.Manager, as: NetManager
  alias AeroVision.Network.Watchdog

  # ── helpers ──────────────────────────────────────────────────────────────

  defp on_time_flight do
    now = DateTime.utc_now()

    %TrackedFlight{
      state_vector: %StateVector{
        icao24: "abc123",
        callsign: "AAL1234",
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
        ident: "AAL1234",
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
        actual_departure_time: DateTime.add(now, -3600),
        arrival_time: DateTime.add(now, 3600),
        estimated_arrival_time: DateTime.add(now, 3600),
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

  # ── setup ──────────────────────────────────────────────────────────────

  setup :set_mimic_global

  setup do
    Store.reset()
    # Seed config so compute_setup_step/1 returns :done and the flight dashboard renders.
    # Conditions for :done:
    #   1. wifi_ssid must be non-nil and non-empty
    #   2. has_any_api_keys? must be true (skylink_api_key or opensky_client_id)
    #   3. location must NOT be the default (35.7721, -78.63861)
    Store.put(:wifi_ssid, "TestNetwork")
    Store.put(:skylink_api_key, "test-key")
    Store.put(:location_lat, 35.8)
    Store.put(:location_lon, -78.6)

    stub(NetManager, :current_mode, fn -> :infrastructure end)
    stub(NetManager, :current_ip, fn -> "192.168.1.42" end)
    stub(Watchdog, :ping, fn -> :ok end)
    stub(Tracker, :get_flights, fn -> [] end)
    stub(Tracker, :broadcast_now, fn -> :ok end)
    stub(FlightStatus, :re_enrich, fn _callsign -> :ok end)

    :ok
  end

  # ── refresh button ──────────────────────────────────────────────────────

  describe "refresh flight button" do
    test "clicking refresh calls FlightStatus.re_enrich with the callsign", %{conn: conn} do
      flight = on_time_flight()
      stub(Tracker, :get_flights, fn -> [flight] end)

      {:ok, view, _html} = live(conn, "/")

      expect(FlightStatus, :re_enrich, fn callsign ->
        assert callsign == "AAL1234"
        :ok
      end)

      view
      |> element("button[phx-click='refresh_flight'][phx-value-callsign='AAL1234']")
      |> render_click()
    end

    test "clicking refresh shows spinner animation class", %{conn: conn} do
      flight = on_time_flight()
      stub(Tracker, :get_flights, fn -> [flight] end)

      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> element("button[phx-click='refresh_flight'][phx-value-callsign='AAL1234']")
        |> render_click()

      assert html =~ "animate-spin"
    end
  end

  # ── delay coloring ──────────────────────────────────────────────────────

  describe "delay coloring in flight cards" do
    test "on-time flight shows gray time color", %{conn: conn} do
      flight = on_time_flight()
      stub(Tracker, :get_flights, fn -> [flight] end)

      {:ok, _view, html} = live(conn, "/")

      # On-time flight should have text-gray-500 for times (default color)
      # and should NOT have orange or red delay colors
      refute html =~ "text-orange-400"
      refute html =~ "text-red-400"
    end

    test "45-min delayed departure shows orange class", %{conn: conn} do
      flight = delayed_flight(45, 0)
      stub(Tracker, :get_flights, fn -> [flight] end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "text-orange-400"
    end

    test "90-min delayed arrival shows red class", %{conn: conn} do
      flight = delayed_flight(0, 90)
      stub(Tracker, :get_flights, fn -> [flight] end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "text-red-400"
    end

    test "flight with both delays shows both orange and red", %{conn: conn} do
      flight = delayed_flight(30, 75)
      stub(Tracker, :get_flights, fn -> [flight] end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "text-orange-400"
      assert html =~ "text-red-400"
    end
  end
end
