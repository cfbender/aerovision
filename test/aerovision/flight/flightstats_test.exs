defmodule AeroVision.Flight.FlightStatsTest do
  use ExUnit.Case, async: true

  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightStats

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defp read_fixture(name) do
    @fixtures_dir |> Path.join(name) |> File.read!()
  end

  describe "parse_html/1 with scheduled flight" do
    setup do
      html = read_fixture("flightstats_scheduled.html")
      {:ok, info} = FlightStats.parse_html(html)
      %{info: info}
    end

    test "extracts flight identifier", %{info: info} do
      assert info.ident == "DL1209"
    end

    test "extracts operator ICAO code", %{info: info} do
      assert info.operator == "DAL"
    end

    test "extracts airline name", %{info: info} do
      assert info.airline_name == "Delta Air Lines"
    end

    test "extracts aircraft type", %{info: info} do
      assert info.aircraft_type == "7S9"
    end

    test "extracts aircraft name", %{info: info} do
      assert info.aircraft_name == "Boeing 737-900 Passenger (Scimitar Winglets)"
    end

    test "extracts origin airport", %{info: info} do
      assert %Airport{
               iata: "SLC",
               name: "Salt Lake City International Airport",
               city: "Salt Lake City"
             } =
               info.origin
    end

    test "extracts destination airport", %{info: info} do
      assert %Airport{iata: "PDX", name: "Portland International Airport", city: "Portland"} =
               info.destination
    end

    test "extracts scheduled departure time as UTC", %{info: info} do
      assert info.departure_time == ~U[2026-03-18 17:36:00.000Z]
    end

    test "has nil actual departure time for scheduled flight", %{info: info} do
      assert is_nil(info.actual_departure_time)
    end

    test "extracts scheduled arrival time as UTC", %{info: info} do
      assert info.arrival_time == ~U[2026-03-18 19:35:00.000Z]
    end

    test "extracts estimated arrival time", %{info: info} do
      assert info.estimated_arrival_time == ~U[2026-03-18 19:28:00.000Z]
    end

    test "has nil estimated departure time for scheduled flight", %{info: info} do
      # estimatedActualDepartureTitle is "Estimated" but UTC value is null
      assert is_nil(info.estimated_departure_time)
    end

    test "extracts status", %{info: info} do
      assert info.status == "Scheduled"
    end

    test "sets cached_at to a recent DateTime", %{info: info} do
      assert %DateTime{} = info.cached_at
      assert DateTime.diff(DateTime.utc_now(), info.cached_at) < 5
    end

    test "progress_pct is nil", %{info: info} do
      assert is_nil(info.progress_pct)
    end
  end

  describe "parse_html/1 with in-flight (departed) flight" do
    setup do
      html = read_fixture("flightstats_inflight.html")
      {:ok, info} = FlightStats.parse_html(html)
      %{info: info}
    end

    test "extracts flight identifier", %{info: info} do
      assert info.ident == "TK33"
    end

    test "extracts operator ICAO code", %{info: info} do
      assert info.operator == "THY"
    end

    test "extracts airline name", %{info: info} do
      assert info.airline_name == "Turkish Airlines"
    end

    test "extracts aircraft type", %{info: info} do
      assert info.aircraft_type == "789"
    end

    test "extracts aircraft name", %{info: info} do
      assert info.aircraft_name == "Boeing 787-9"
    end

    test "extracts origin airport (international)", %{info: info} do
      assert %Airport{iata: "IST", name: "Istanbul Airport", city: "Istanbul"} = info.origin
    end

    test "extracts destination airport", %{info: info} do
      assert %Airport{iata: "IAH", city: "Houston"} = info.destination
    end

    test "extracts scheduled departure time as UTC", %{info: info} do
      assert info.departure_time == ~U[2026-03-18 11:50:00.000Z]
    end

    test "extracts actual departure time (not estimated)", %{info: info} do
      # estimatedActualDepartureTitle is "Actual"
      assert info.actual_departure_time == ~U[2026-03-18 11:53:00.000Z]
    end

    test "has nil estimated departure time when actual is available", %{info: info} do
      assert is_nil(info.estimated_departure_time)
    end

    test "extracts scheduled arrival time as UTC", %{info: info} do
      assert info.arrival_time == ~U[2026-03-19 01:10:00.000Z]
    end

    test "extracts estimated arrival time", %{info: info} do
      assert info.estimated_arrival_time == ~U[2026-03-19 00:49:00.000Z]
    end

    test "has nil actual arrival time when still in flight", %{info: info} do
      # estimatedActualArrivalTitle is "Estimated", not "Actual"
      # So there's no actual arrival yet — it's in the estimated_arrival_time field
      # But actual DEPARTURE exists
      assert info.actual_departure_time == ~U[2026-03-18 11:53:00.000Z]
      # And no actual arrival (only estimated)
      assert is_nil(info.arrival_time) == false
      assert is_nil(info.estimated_arrival_time) == false
    end

    test "status maps Departed to En Route", %{info: info} do
      assert info.status == "En Route"
    end
  end

  describe "parse_html/1 with no flight data" do
    test "returns error when flight is null" do
      html = read_fixture("flightstats_no_flight.html")
      assert {:error, :no_flight_data} = FlightStats.parse_html(html)
    end
  end

  describe "parse_html/1 error handling" do
    test "returns error for empty HTML" do
      assert {:error, _} = FlightStats.parse_html("")
    end

    test "returns error for HTML without __NEXT_DATA__" do
      html = "<html><body><script>var x = 1;</script></body></html>"
      assert {:error, :no_next_data} = FlightStats.parse_html(html)
    end

    test "returns error for malformed JSON in __NEXT_DATA__" do
      html = ~s(<html><body><script>__NEXT_DATA__ = {not valid json}</script></body></html>)
      assert {:error, _} = FlightStats.parse_html(html)
    end

    test "returns error for __NEXT_DATA__ missing flightTracker" do
      html =
        ~s(<html><body><script>__NEXT_DATA__ = {"props":{"initialState":{"flightTracker":{"flight":null}}}}</script></body></html>)

      assert {:error, :no_flight_data} = FlightStats.parse_html(html)
    end
  end

  describe "airport parsing" do
    test "airport icao is nil (not available from flight-tracker)" do
      html = read_fixture("flightstats_scheduled.html")
      {:ok, info} = FlightStats.parse_html(html)
      assert is_nil(info.origin.icao)
      assert is_nil(info.destination.icao)
    end
  end

  describe "result struct shape" do
    test "returns a proper FlightInfo struct" do
      html = read_fixture("flightstats_scheduled.html")
      assert {:ok, %FlightInfo{}} = FlightStats.parse_html(html)
    end

    test "inflight result is a proper FlightInfo struct" do
      html = read_fixture("flightstats_inflight.html")
      assert {:ok, %FlightInfo{}} = FlightStats.parse_html(html)
    end
  end

  describe "parse_html/1 with truncated response" do
    test "returns :no_next_data for truncated JSON in __NEXT_DATA__" do
      html = read_fixture("flightstats_truncated.html")
      # With the balanced brace scanner, truncated JSON has unbalanced braces,
      # so find_closing_brace/4 returns :error → no JSON extracted → :no_next_data
      assert {:error, :no_next_data} = FlightStats.parse_html(html)
    end
  end

  describe "parse_html/1 with trailing JavaScript after __NEXT_DATA__" do
    setup do
      html = read_fixture("flightstats_trailing_js.html")
      {:ok, info} = FlightStats.parse_html(html)
      %{info: info}
    end

    test "correctly extracts JSON despite trailing JS code", %{info: info} do
      assert info.ident == "WN3137"
      assert info.airline_name == "Southwest Airlines"
    end

    test "extracts airports correctly", %{info: info} do
      assert info.origin.iata == "HOU"
      assert info.destination.iata == "DCA"
    end

    test "extracts equipment correctly", %{info: info} do
      assert info.aircraft_type == "7M8"
      assert info.aircraft_name == "Boeing 737MAX 8 Passenger"
    end

    test "maps Departed status to En Route", %{info: info} do
      assert info.status == "En Route"
    end

    test "extracts actual departure time", %{info: info} do
      assert info.actual_departure_time == ~U[2026-03-18 13:20:00.000Z]
    end
  end
end
