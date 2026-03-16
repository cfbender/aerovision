defmodule AeroVision.Flight.GeoUtilsTest do
  use ExUnit.Case, async: true
  alias AeroVision.Flight.GeoUtils

  # ──────────────────────────────────────────────── haversine_km ──

  describe "haversine_km/4" do
    test "same point returns 0.0" do
      assert GeoUtils.haversine_km(35.8776, -78.7875, 35.8776, -78.7875) == 0.0
    end

    test "RDU to JFK is approximately 687 km" do
      # RDU: 35.8776°N, 78.7875°W  →  JFK: 40.6413°N, 73.7781°W
      # Great-circle distance ≈ 687 km
      result = GeoUtils.haversine_km(35.8776, -78.7875, 40.6413, -73.7781)
      assert_in_delta result, 687.0, 5.0
    end

    test "is symmetric — haversine(a,b,c,d) == haversine(c,d,a,b)" do
      d1 = GeoUtils.haversine_km(35.8776, -78.7875, 40.6413, -73.7781)
      d2 = GeoUtils.haversine_km(40.6413, -73.7781, 35.8776, -78.7875)
      assert_in_delta d1, d2, 0.0001
    end

    test "antipodal points (0,0) to (0,180) ≈ 20015 km" do
      result = GeoUtils.haversine_km(0.0, 0.0, 0.0, 180.0)
      assert_in_delta result, 20_015.0, 5.0
    end
  end

  # ──────────────────────────────────────────────── bounding_box ──

  describe "bounding_box/3" do
    test "radius 0 produces a degenerate box where min == max for each axis" do
      {min_lat, min_lon, max_lat, max_lon} = GeoUtils.bounding_box(35.0, -78.0, 0)
      assert_in_delta min_lat, 35.0, 0.0001
      assert_in_delta max_lat, 35.0, 0.0001
      assert_in_delta min_lon, -78.0, 0.0001
      assert_in_delta max_lon, -78.0, 0.0001
    end

    test "positive radius produces max_lat > min_lat and max_lon > min_lon" do
      {min_lat, min_lon, max_lat, max_lon} = GeoUtils.bounding_box(35.0, -78.0, 50)
      assert max_lat > min_lat
      assert max_lon > min_lon
    end

    test "lat span is approximately 2 * radius / 111 degrees" do
      radius_km = 111.0
      {min_lat, _min_lon, max_lat, _max_lon} = GeoUtils.bounding_box(35.0, -78.0, radius_km)
      expected_span = 2 * radius_km / 111.0
      assert_in_delta max_lat - min_lat, expected_span, 0.5
    end

    test "center point is inside the returned box" do
      lat = 35.0
      lon = -78.0
      {min_lat, min_lon, max_lat, max_lon} = GeoUtils.bounding_box(lat, lon, 50)
      assert min_lat < lat and lat < max_lat
      assert min_lon < lon and lon < max_lon
    end
  end

  # ──────────────────────────────────────────────── meters_to_feet ──

  describe "meters_to_feet/1" do
    test "nil returns nil" do
      assert GeoUtils.meters_to_feet(nil) == nil
    end

    test "0 returns 0.0" do
      assert GeoUtils.meters_to_feet(0) == 0.0
    end

    test "1.0 meter ≈ 3.28084 feet" do
      assert_in_delta GeoUtils.meters_to_feet(1.0), 3.28084, 0.001
    end

    test "10000 meters ≈ 32808.4 feet" do
      assert_in_delta GeoUtils.meters_to_feet(10_000), 32_808.4, 1.0
    end
  end

  # ──────────────────────────────────────────────── ms_to_knots ──

  describe "ms_to_knots/1" do
    test "nil returns nil" do
      assert GeoUtils.ms_to_knots(nil) == nil
    end

    test "0 returns 0.0" do
      assert GeoUtils.ms_to_knots(0) == 0.0
    end

    test "1.0 m/s ≈ 1.94384 knots" do
      assert_in_delta GeoUtils.ms_to_knots(1.0), 1.94384, 0.001
    end

    test "100.0 m/s ≈ 194.384 knots" do
      assert_in_delta GeoUtils.ms_to_knots(100.0), 194.384, 0.1
    end
  end

  # ──────────────────────────────────────────────── flight_progress ──

  describe "flight_progress/6" do
    # Use RDU → JFK as the route for progress tests
    @origin_lat 35.8776
    @origin_lon -78.7875
    @dest_lat 40.6413
    @dest_lon -73.7781

    test "at the origin (same coords as origin) returns 0.0" do
      result =
        GeoUtils.flight_progress(
          @origin_lat,
          @origin_lon,
          @dest_lat,
          @dest_lon,
          @origin_lat,
          @origin_lon
        )

      assert_in_delta result, 0.0, 0.001
    end

    test "at the destination returns 1.0" do
      result =
        GeoUtils.flight_progress(
          @origin_lat,
          @origin_lon,
          @dest_lat,
          @dest_lon,
          @dest_lat,
          @dest_lon
        )

      assert_in_delta result, 1.0, 0.001
    end

    test "at geographic midpoint returns approximately 0.5" do
      mid_lat = (@origin_lat + @dest_lat) / 2.0
      mid_lon = (@origin_lon + @dest_lon) / 2.0

      result =
        GeoUtils.flight_progress(@origin_lat, @origin_lon, @dest_lat, @dest_lon, mid_lat, mid_lon)

      assert_in_delta result, 0.5, 0.05
    end

    test "past the destination is clamped to 1.0 via min/1" do
      # Put the current position beyond the destination from the origin's perspective
      # by mirroring the destination coordinates further along
      overshoot_lat = @dest_lat + (@dest_lat - @origin_lat)
      overshoot_lon = @dest_lon + (@dest_lon - @origin_lon)

      result =
        GeoUtils.flight_progress(
          @origin_lat,
          @origin_lon,
          @dest_lat,
          @dest_lon,
          overshoot_lat,
          overshoot_lon
        )

      assert result == 1.0
    end

    test "nil current coordinates returns nil" do
      assert GeoUtils.flight_progress(@origin_lat, @origin_lon, @dest_lat, @dest_lon, nil, nil) ==
               nil
    end

    test "nil origin coordinates returns nil" do
      assert GeoUtils.flight_progress(
               nil,
               @origin_lon,
               @dest_lat,
               @dest_lon,
               @origin_lat,
               @origin_lon
             ) == nil
    end

    test "origin equals destination (total distance 0) returns 0.0" do
      result =
        GeoUtils.flight_progress(
          @origin_lat,
          @origin_lon,
          @origin_lat,
          @origin_lon,
          @origin_lat,
          @origin_lon
        )

      assert result == 0.0
    end
  end
end
