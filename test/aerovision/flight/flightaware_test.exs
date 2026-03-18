defmodule AeroVision.Flight.FlightAwareTest do
  use ExUnit.Case, async: true

  alias AeroVision.Flight.FlightAware
  alias AeroVision.Flight.{FlightInfo, Airport}

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defp read_fixture(name) do
    Path.join(@fixtures_dir, name) |> File.read!()
  end

  describe "parse_html/1 with arrived flight" do
    setup do
      html = read_fixture("flightaware_arrived.html")
      {:ok, info} = FlightAware.parse_html(html)
      %{info: info}
    end

    test "extracts flight identifier", %{info: info} do
      assert info.ident == "SWA3137"
    end

    test "extracts operator ICAO code", %{info: info} do
      assert info.operator == "SWA"
    end

    test "extracts airline name", %{info: info} do
      assert info.airline_name == "Southwest"
    end

    test "extracts aircraft type", %{info: info} do
      assert info.aircraft_type == "B38M"
    end

    test "extracts aircraft name", %{info: info} do
      assert info.aircraft_name =~ "Boeing 737 MAX 8"
    end

    test "extracts origin airport", %{info: info} do
      assert %Airport{
               icao: "KHOU",
               iata: "HOU",
               name: "William P Hobby",
               city: "Houston, TX"
             } = info.origin
    end

    test "extracts destination airport", %{info: info} do
      assert %Airport{
               icao: "KDCA",
               iata: "DCA",
               name: "Reagan National",
               city: "Washington, DC"
             } = info.destination
    end

    test "extracts scheduled departure time from unix epoch", %{info: info} do
      assert info.departure_time == DateTime.from_unix!(1_773_840_300)
    end

    test "extracts actual departure time from unix epoch", %{info: info} do
      assert info.actual_departure_time == DateTime.from_unix!(1_773_840_000)
    end

    test "extracts scheduled arrival time from unix epoch", %{info: info} do
      assert info.arrival_time == DateTime.from_unix!(1_773_850_500)
    end

    test "extracts estimated arrival time from unix epoch", %{info: info} do
      assert info.estimated_arrival_time == DateTime.from_unix!(1_773_850_440)
    end

    test "normalizes arrived status to Landed", %{info: info} do
      assert info.status == "Landed"
    end

    test "computes progress_pct as 1.0 when remaining is zero", %{info: info} do
      # elapsed=1059, remaining=0 → 1059 / (1059 + 0) = 1.0
      assert info.progress_pct == 1.0
    end

    test "sets cached_at to a recent DateTime", %{info: info} do
      assert %DateTime{} = info.cached_at
      assert DateTime.diff(DateTime.utc_now(), info.cached_at) < 5
    end

    test "returns a proper FlightInfo struct", %{info: info} do
      assert %FlightInfo{} = info
    end
  end

  describe "parse_html/1 with en-route flight" do
    setup do
      html = read_fixture("flightaware_enroute.html")
      {:ok, info} = FlightAware.parse_html(html)
      %{info: info}
    end

    test "extracts flight identifier", %{info: info} do
      assert info.ident == "DAL1209"
    end

    test "extracts operator ICAO code", %{info: info} do
      assert info.operator == "DAL"
    end

    test "normalizes empty flightStatus with actual departure to Scheduled", %{info: info} do
      # flightStatus is "" — no non-empty status string, so falls through to Scheduled
      # (The task spec says empty string → "Scheduled")
      assert info.status == "Scheduled"
    end

    test "computes progress_pct between 0.0 and 1.0", %{info: info} do
      # elapsed=500, remaining=559 → 500 / (500 + 559) ≈ 0.472
      assert is_float(info.progress_pct)
      assert info.progress_pct > 0.0
      assert info.progress_pct < 1.0
    end

    test "progress_pct matches expected ratio", %{info: info} do
      expected = 500 / (500 + 559)
      assert_in_delta info.progress_pct, expected, 0.0001
    end

    test "actual departure time is set", %{info: info} do
      assert %DateTime{} = info.actual_departure_time
      assert info.actual_departure_time == DateTime.from_unix!(1_773_840_000)
    end

    test "estimated arrival time is set (no actual arrival yet)", %{info: info} do
      assert %DateTime{} = info.estimated_arrival_time
      assert info.estimated_arrival_time == DateTime.from_unix!(1_773_850_440)
    end

    test "origin airport has ICAO and IATA codes", %{info: info} do
      assert info.origin.icao == "KSLC"
      assert info.origin.iata == "SLC"
    end

    test "destination airport has ICAO and IATA codes", %{info: info} do
      assert info.destination.icao == "KPDX"
      assert info.destination.iata == "PDX"
    end

    test "returns a proper FlightInfo struct", %{info: info} do
      assert %FlightInfo{} = info
    end
  end

  describe "parse_html/1 with no flight data" do
    test "returns :no_flight_data when flights map is empty" do
      html = read_fixture("flightaware_no_flight.html")
      assert {:error, :no_flight_data} = FlightAware.parse_html(html)
    end
  end

  describe "parse_html/1 with no bootstrap" do
    test "returns :no_bootstrap_data when trackpollBootstrap is absent" do
      html = read_fixture("flightaware_no_bootstrap.html")
      assert {:error, :no_bootstrap_data} = FlightAware.parse_html(html)
    end
  end

  describe "parse_html/1 error handling" do
    test "returns error for empty HTML" do
      assert {:error, _} = FlightAware.parse_html("")
    end

    test "returns :no_bootstrap_data for HTML without trackpollBootstrap" do
      html = "<html><body><script>var x = 1;</script></body></html>"
      assert {:error, :no_bootstrap_data} = FlightAware.parse_html(html)
    end

    test "returns :no_flight_data for bootstrap with null flights" do
      html =
        ~s(<html><body><script>var trackpollBootstrap = {"version":"2.24","flights":{}}</script></body></html>)

      assert {:error, :no_flight_data} = FlightAware.parse_html(html)
    end
  end

  describe "status normalization" do
    test "cancelled flag takes precedence over flightStatus" do
      html =
        ~s(<html><body><script>var trackpollBootstrap = {"version":"2.24","summary":false,"flights":{"F1":{"ident":"TST1","airline":{},"aircraft":{},"origin":{},"destination":{},"gateDepartureTimes":{},"gateArrivalTimes":{},"distance":{},"flightStatus":"en route","cancelled":true,"diverted":false}}}</script></body></html>)

      {:ok, info} = FlightAware.parse_html(html)
      assert info.status == "Cancelled"
    end

    test "diverted flag takes precedence over flightStatus" do
      html =
        ~s(<html><body><script>var trackpollBootstrap = {"version":"2.24","summary":false,"flights":{"F1":{"ident":"TST1","airline":{},"aircraft":{},"origin":{},"destination":{},"gateDepartureTimes":{},"gateArrivalTimes":{},"distance":{},"flightStatus":"en route","cancelled":false,"diverted":true}}}</script></body></html>)

      {:ok, info} = FlightAware.parse_html(html)
      assert info.status == "Diverted"
    end

    test "arrived flightStatus maps to Landed" do
      html = read_fixture("flightaware_arrived.html")
      {:ok, info} = FlightAware.parse_html(html)
      assert info.status == "Landed"
    end

    test "non-empty non-arrived flightStatus maps to En Route" do
      html =
        ~s(<html><body><script>var trackpollBootstrap = {"version":"2.24","summary":false,"flights":{"F1":{"ident":"TST1","airline":{},"aircraft":{},"origin":{},"destination":{},"gateDepartureTimes":{},"gateArrivalTimes":{},"distance":{},"flightStatus":"en route","cancelled":false,"diverted":false}}}</script></body></html>)

      {:ok, info} = FlightAware.parse_html(html)
      assert info.status == "En Route"
    end

    test "empty flightStatus maps to Scheduled" do
      html = read_fixture("flightaware_enroute.html")
      {:ok, info} = FlightAware.parse_html(html)
      # flightStatus is "" in this fixture → Scheduled
      assert info.status == "Scheduled"
    end
  end

  describe "progress computation" do
    test "elapsed=500, remaining=559 gives ~0.472" do
      html = read_fixture("flightaware_enroute.html")
      {:ok, info} = FlightAware.parse_html(html)
      assert_in_delta info.progress_pct, 500 / (500 + 559), 0.0001
    end

    test "elapsed=1059, remaining=0 gives 1.0" do
      html = read_fixture("flightaware_arrived.html")
      {:ok, info} = FlightAware.parse_html(html)
      assert info.progress_pct == 1.0
    end

    test "elapsed=0, remaining=0 gives nil" do
      html =
        ~s(<html><body><script>var trackpollBootstrap = {"version":"2.24","summary":false,"flights":{"F1":{"ident":"TST1","airline":{},"aircraft":{},"origin":{},"destination":{},"gateDepartureTimes":{},"gateArrivalTimes":{},"distance":{"elapsed":0,"remaining":0},"flightStatus":"","cancelled":false,"diverted":false}}}</script></body></html>)

      {:ok, info} = FlightAware.parse_html(html)
      assert is_nil(info.progress_pct)
    end

    test "nil distance gives nil progress" do
      html =
        ~s(<html><body><script>var trackpollBootstrap = {"version":"2.24","summary":false,"flights":{"F1":{"ident":"TST1","airline":{},"aircraft":{},"origin":{},"destination":{},"gateDepartureTimes":{},"gateArrivalTimes":{},"distance":{},"flightStatus":"","cancelled":false,"diverted":false}}}</script></body></html>)

      {:ok, info} = FlightAware.parse_html(html)
      assert is_nil(info.progress_pct)
    end
  end
end
