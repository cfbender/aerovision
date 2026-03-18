defmodule AeroVision.Flight.Utils.Geo do
  @moduledoc "Geographic utility functions for flight tracking."

  @earth_radius_km 6371.0

  @doc "Calculate haversine distance between two points in kilometers."
  def haversine_km(lat1, lon1, lat2, lon2) do
    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  @doc """
  Calculate a bounding box from a center point and radius.
  Returns {min_lat, min_lon, max_lat, max_lon}.
  """
  def bounding_box(lat, lon, radius_km) do
    lat_delta = radius_km / 111.0
    lon_delta = radius_km / (111.0 * :math.cos(deg_to_rad(lat)))

    {lat - lat_delta, lon - lon_delta, lat + lat_delta, lon + lon_delta}
  end

  @doc "Convert meters to feet."
  def meters_to_feet(nil), do: nil
  def meters_to_feet(meters), do: meters * 3.28084

  @doc "Convert m/s to knots."
  def ms_to_knots(nil), do: nil
  def ms_to_knots(ms), do: ms * 1.94384

  @doc "Calculate flight progress as a percentage (0.0-1.0)."
  def flight_progress(origin_lat, origin_lon, dest_lat, dest_lon, current_lat, current_lon)
      when is_number(origin_lat) and is_number(dest_lat) and is_number(current_lat) do
    total = haversine_km(origin_lat, origin_lon, dest_lat, dest_lon)
    covered = haversine_km(origin_lat, origin_lon, current_lat, current_lon)

    if total > 0, do: min(covered / total, 1.0), else: 0.0
  end

  def flight_progress(_, _, _, _, _, _), do: nil

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
