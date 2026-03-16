defmodule AeroVision.Flight.StateVectorTest do
  use ExUnit.Case, async: true
  alias AeroVision.Flight.StateVector

  # A well-formed 17-element list matching OpenSky's array format:
  # [icao24, callsign, origin_country, time_position, last_contact,
  #  longitude, latitude, baro_altitude, on_ground, velocity,
  #  true_track, vertical_rate, sensors, geo_altitude, squawk,
  #  spi, position_source]
  defp valid_array do
    [
      # icao24
      "a1b2c3",
      # callsign (with trailing space)
      "AAL1234 ",
      # origin_country
      "United States",
      # time_position (unix)
      1_741_996_800,
      # last_contact (unix)
      1_741_996_810,
      # longitude
      -78.7875,
      # latitude
      35.8776,
      # baro_altitude (meters)
      10_668.0,
      # on_ground
      false,
      # velocity (m/s)
      257.0,
      # true_track (degrees)
      045.0,
      # vertical_rate (m/s)
      2.5,
      # sensors (ignored)
      nil,
      # geo_altitude (meters)
      10_972.8,
      # squawk
      "1200",
      # spi (ignored)
      false,
      # position_source (0=ADS-B)
      0
    ]
  end

  # ──────────────────────────────────────────────── happy path ──

  describe "from_array/1 with valid input" do
    test "returns a %StateVector{} struct" do
      assert %StateVector{} = StateVector.from_array(valid_array())
    end

    test "maps icao24 correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.icao24 == "a1b2c3"
    end

    test "trims trailing spaces from callsign" do
      sv = StateVector.from_array(valid_array())
      assert sv.callsign == "AAL1234"
    end

    test "maps origin_country correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.origin_country == "United States"
    end

    test "maps time_position correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.time_position == 1_741_996_800
    end

    test "maps last_contact correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.last_contact == 1_741_996_810
    end

    test "maps longitude correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.longitude == -78.7875
    end

    test "maps latitude correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.latitude == 35.8776
    end

    test "maps baro_altitude correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.baro_altitude == 10_668.0
    end

    test "maps on_ground correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.on_ground == false
    end

    test "maps velocity correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.velocity == 257.0
    end

    test "maps true_track correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.true_track == 45.0
    end

    test "maps vertical_rate correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.vertical_rate == 2.5
    end

    test "skips sensors field (index 12)" do
      # sensors is in the struct definition but not a struct field — just verify parse succeeds
      sv = StateVector.from_array(valid_array())
      assert %StateVector{} = sv
    end

    test "maps geo_altitude correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.geo_altitude == 10_972.8
    end

    test "maps squawk correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.squawk == "1200"
    end

    test "maps position_source correctly" do
      sv = StateVector.from_array(valid_array())
      assert sv.position_source == 0
    end
  end

  # ──────────────────────────────────────────────── callsign edge cases ──

  describe "from_array/1 callsign handling" do
    test "nil callsign is preserved as nil, does not crash" do
      arr = List.replace_at(valid_array(), 1, nil)
      sv = StateVector.from_array(arr)
      assert sv.callsign == nil
    end

    test "callsign with no spaces is left untouched" do
      arr = List.replace_at(valid_array(), 1, "UAL456")
      sv = StateVector.from_array(arr)
      assert sv.callsign == "UAL456"
    end
  end

  # ──────────────────────────────────────────────── on_ground flag ──

  describe "from_array/1 on_ground flag" do
    test "on_ground true is preserved" do
      arr = List.replace_at(valid_array(), 8, true)
      sv = StateVector.from_array(arr)
      assert sv.on_ground == true
    end
  end

  # ──────────────────────────────────────────────── nil numeric fields ──

  describe "from_array/1 nil fields" do
    test "nil values in numeric fields are preserved, not converted" do
      arr =
        valid_array()
        # time_position
        |> List.replace_at(3, nil)
        # longitude
        |> List.replace_at(5, nil)
        # latitude
        |> List.replace_at(6, nil)
        # baro_altitude
        |> List.replace_at(7, nil)
        # velocity
        |> List.replace_at(9, nil)
        # true_track
        |> List.replace_at(10, nil)
        # vertical_rate
        |> List.replace_at(11, nil)
        # geo_altitude
        |> List.replace_at(13, nil)

      sv = StateVector.from_array(arr)
      assert sv.time_position == nil
      assert sv.longitude == nil
      assert sv.latitude == nil
      assert sv.baro_altitude == nil
      assert sv.velocity == nil
      assert sv.true_track == nil
      assert sv.vertical_rate == nil
      assert sv.geo_altitude == nil
    end
  end

  # ──────────────────────────────────────────────── too-short arrays ──

  describe "from_array/1 with malformed input" do
    test "empty array returns nil" do
      assert StateVector.from_array([]) == nil
    end

    test "array with 10 elements returns nil" do
      assert StateVector.from_array(Enum.take(valid_array(), 10)) == nil
    end

    test "array with exactly 16 elements returns nil" do
      assert StateVector.from_array(Enum.take(valid_array(), 16)) == nil
    end

    test "array with 17 elements (minimum valid) parses successfully" do
      assert %StateVector{} = StateVector.from_array(Enum.take(valid_array(), 17))
    end

    test "array with extra trailing elements parses successfully, extras ignored" do
      extended = valid_array() ++ ["extra1", "extra2", 99]
      assert %StateVector{} = StateVector.from_array(extended)
    end
  end
end
