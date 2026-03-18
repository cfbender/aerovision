defmodule AeroVision.Flight.StateVectorTest do
  use ExUnit.Case, async: true
  alias AeroVision.Flight.StateVector

  # A well-formed Skylink-format map matching the fields returned by the
  # /adsb/aircraft endpoint.
  defp valid_map do
    %{
      "icao24" => "40621D",
      "callsign" => "BAW123 ",
      "latitude" => 51.47,
      "longitude" => -0.46,
      "altitude" => 35_000.0,
      "ground_speed" => 450.5,
      "track" => 89.2,
      "vertical_rate" => 0.0,
      "is_on_ground" => false,
      "last_seen" => "2026-02-11T12:00:00Z",
      "first_seen" => "2026-02-11T11:45:00Z",
      "registration" => "G-STBC",
      "aircraft_type" => "Boeing 777",
      "airline" => "British Airways"
    }
  end

  # ──────────────────────────────────────────────── happy path ──

  describe "from_skylink/1 with valid input" do
    test "returns a %StateVector{} struct" do
      assert %StateVector{} = StateVector.from_skylink(valid_map())
    end

    test "maps icao24 correctly" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.icao24 == "40621D"
    end

    test "trims trailing spaces from callsign" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.callsign == "BAW123"
    end

    test "maps latitude correctly" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.latitude == 51.47
    end

    test "maps longitude correctly" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.longitude == -0.46
    end

    test "maps baro_altitude from altitude field" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.baro_altitude == 35_000.0
    end

    test "maps velocity from ground_speed field" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.velocity == 450.5
    end

    test "maps true_track from track field" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.true_track == 89.2
    end

    test "maps vertical_rate correctly" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.vertical_rate == 0.0
    end

    test "maps on_ground from is_on_ground field" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.on_ground == false
    end

    test "parses last_seen ISO 8601 string to unix timestamp" do
      sv = StateVector.from_skylink(valid_map())
      # 2026-02-11T12:00:00Z → unix
      assert sv.last_contact == DateTime.to_unix(~U[2026-02-11 12:00:00Z])
    end

    test "parses first_seen ISO 8601 string to unix timestamp for time_position" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.time_position == DateTime.to_unix(~U[2026-02-11 11:45:00Z])
    end

    test "geo_altitude is nil (not in Skylink format)" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.geo_altitude == nil
    end

    test "squawk is nil (not in Skylink format)" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.squawk == nil
    end

    test "position_source is nil (not in Skylink format)" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.position_source == nil
    end

    test "origin_country is nil (not in Skylink format)" do
      sv = StateVector.from_skylink(valid_map())
      assert sv.origin_country == nil
    end
  end

  # ──────────────────────────────────────────────── callsign edge cases ──

  describe "from_skylink/1 callsign handling" do
    test "nil callsign is preserved as nil, does not crash" do
      sv = StateVector.from_skylink(Map.put(valid_map(), "callsign", nil))
      assert sv.callsign == nil
    end

    test "callsign with no spaces is left untouched" do
      sv = StateVector.from_skylink(Map.put(valid_map(), "callsign", "UAL456"))
      assert sv.callsign == "UAL456"
    end

    test "callsign with only spaces becomes empty string" do
      sv = StateVector.from_skylink(Map.put(valid_map(), "callsign", "   "))
      assert sv.callsign == ""
    end
  end

  # ──────────────────────────────────────────────── on_ground flag ──

  describe "from_skylink/1 on_ground flag" do
    test "on_ground true is preserved" do
      sv = StateVector.from_skylink(Map.put(valid_map(), "is_on_ground", true))
      assert sv.on_ground == true
    end

    test "missing is_on_ground defaults to false" do
      sv = StateVector.from_skylink(Map.delete(valid_map(), "is_on_ground"))
      assert sv.on_ground == false
    end
  end

  # ──────────────────────────────────────────────── nil numeric fields ──

  describe "from_skylink/1 nil fields" do
    test "nil values in numeric fields are preserved, not converted" do
      data =
        valid_map()
        |> Map.put("longitude", nil)
        |> Map.put("latitude", nil)
        |> Map.put("altitude", nil)
        |> Map.put("ground_speed", nil)
        |> Map.put("track", nil)
        |> Map.put("vertical_rate", nil)

      sv = StateVector.from_skylink(data)
      assert sv.longitude == nil
      assert sv.latitude == nil
      assert sv.baro_altitude == nil
      assert sv.velocity == nil
      assert sv.true_track == nil
      assert sv.vertical_rate == nil
    end

    test "nil last_seen produces nil last_contact" do
      sv = StateVector.from_skylink(Map.put(valid_map(), "last_seen", nil))
      assert sv.last_contact == nil
    end

    test "nil first_seen produces nil time_position" do
      sv = StateVector.from_skylink(Map.put(valid_map(), "first_seen", nil))
      assert sv.time_position == nil
    end
  end

  # ──────────────────────────────────────────────── malformed input ──

  describe "from_skylink/1 with malformed input" do
    test "map missing icao24 returns nil" do
      assert StateVector.from_skylink(Map.delete(valid_map(), "icao24")) == nil
    end

    test "map with non-binary icao24 returns nil" do
      assert StateVector.from_skylink(Map.put(valid_map(), "icao24", 12345)) == nil
    end

    test "empty map returns nil" do
      assert StateVector.from_skylink(%{}) == nil
    end

    test "non-map input returns nil" do
      assert StateVector.from_skylink(nil) == nil
      assert StateVector.from_skylink("not a map") == nil
      assert StateVector.from_skylink([]) == nil
    end
  end

  # ──────────────────────────────────────────── from_opensky/1 ──

  # A well-formed 18-element OpenSky array (indices 0–17)
  defp valid_opensky_arr do
    [
      # 0: icao24
      "a1b2c3",
      # 1: callsign (trailing spaces)
      "UAL123  ",
      # 2: origin_country
      "United States",
      # 3: time_position (unix)
      1_739_275_200,
      # 4: last_contact (unix)
      1_739_275_210,
      # 5: longitude
      -87.9073,
      # 6: latitude
      41.9742,
      # 7: baro_altitude (meters)
      1000.0,
      # 8: on_ground
      false,
      # 9: velocity (m/s)
      100.0,
      # 10: true_track (degrees)
      270.0,
      # 11: vertical_rate (m/s)
      5.0,
      # 12: sensors
      nil,
      # 13: geo_altitude (meters)
      990.0,
      # 14: squawk
      "1200",
      # 15: spi
      false,
      # 16: position_source
      0,
      # 17: category
      2
    ]
  end

  describe "from_opensky/1 with valid input" do
    test "returns a %StateVector{} struct" do
      assert %StateVector{} = StateVector.from_opensky(valid_opensky_arr())
    end

    test "maps icao24 correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.icao24 == "a1b2c3"
    end

    test "trims trailing spaces from callsign" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.callsign == "UAL123"
    end

    test "maps origin_country correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.origin_country == "United States"
    end

    test "maps time_position correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.time_position == 1_739_275_200
    end

    test "maps last_contact correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.last_contact == 1_739_275_210
    end

    test "maps longitude correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.longitude == -87.9073
    end

    test "maps latitude correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.latitude == 41.9742
    end

    test "converts baro_altitude from meters to feet (1000 m → 3280.84 ft)" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert_in_delta sv.baro_altitude, 3280.84, 0.01
    end

    test "maps on_ground correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.on_ground == false
    end

    test "converts velocity from m/s to knots (100 m/s → 194.384 knots)" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert_in_delta sv.velocity, 194.384, 0.001
    end

    test "maps true_track correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.true_track == 270.0
    end

    test "converts vertical_rate from m/s to fpm (5 m/s → 984.25 fpm)" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert_in_delta sv.vertical_rate, 984.25, 0.01
    end

    test "maps geo_altitude correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.geo_altitude == 990.0
    end

    test "maps squawk correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.squawk == "1200"
    end

    test "maps position_source correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.position_source == 0
    end

    test "maps category correctly" do
      sv = StateVector.from_opensky(valid_opensky_arr())
      assert sv.category == 2
    end

    test "category is nil when not present in 17-element array" do
      # 17-element array (no category) should still parse fine
      arr = Enum.take(valid_opensky_arr(), 17)
      sv = StateVector.from_opensky(arr)
      assert sv.category == nil
    end
  end

  describe "from_opensky/1 callsign handling" do
    test "nil callsign is preserved as nil" do
      arr = List.replace_at(valid_opensky_arr(), 1, nil)
      sv = StateVector.from_opensky(arr)
      assert sv.callsign == nil
    end

    test "callsign with only whitespace becomes nil" do
      arr = List.replace_at(valid_opensky_arr(), 1, "   ")
      sv = StateVector.from_opensky(arr)
      assert sv.callsign == nil
    end
  end

  describe "from_opensky/1 with malformed input" do
    test "list with fewer than 17 elements returns nil" do
      assert StateVector.from_opensky(Enum.take(valid_opensky_arr(), 16)) == nil
    end

    test "nil input returns nil" do
      assert StateVector.from_opensky(nil) == nil
    end

    test "non-list input returns nil" do
      assert StateVector.from_opensky(%{}) == nil
      assert StateVector.from_opensky("not a list") == nil
    end
  end
end
