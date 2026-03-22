defmodule AeroVision.Flight.Filters do
  @moduledoc """
  Pure functions for filtering, sorting, and ranking tracked flights.

  Used by the Tracker to select which flights to display and enrich.
  All functions are stateless and side-effect free.
  """

  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Utils.Geo

  @max_display_flights 3

  # ─────────────────────────────────────────── filtered flight pipelines ──

  @doc """
  Returns the top flights for display based on the current mode and filters.
  """
  def filtered_flights(%{
        mode: :nearby,
        airline_filters: airline_filters,
        airport_filters: airport_filters,
        flights: flights,
        location_lat: lat,
        location_lon: lon
      }) do
    flights
    |> Map.values()
    |> reject_grounded()
    |> by_airline(airline_filters)
    |> by_airport(airport_filters)
    |> top_nearby(lat, lon)
  end

  def filtered_flights(%{mode: :tracked, tracked_flights: tracked_list, flights: flights}) do
    flights
    |> Map.values()
    |> Enum.filter(fn tracked ->
      callsign = tracked.state_vector.callsign
      Enum.any?(tracked_list, &callsign_matches?(callsign, &1))
    end)
    |> top_by_recency()
  end

  # Fall-through for any unexpected modes
  def filtered_flights(%{flights: flights}) do
    flights |> Map.values() |> top_by_recency()
  end

  # ──────────────────────────────────────────────── airline/airport filters ──

  @doc "Filter flights by airline callsign prefix. Empty list means no filtering."
  def by_airline(flights, []), do: flights

  def by_airline(flights, filters) do
    Enum.filter(flights, fn tracked ->
      callsign = tracked.state_vector.callsign || ""
      Enum.any?(filters, &String.starts_with?(callsign, &1))
    end)
  end

  @doc "Filter flights by origin/destination airport codes. Empty list means no filtering."
  def by_airport(flights, []), do: flights

  def by_airport(flights, filters) do
    normalized = Enum.map(filters, &String.upcase(String.trim(&1)))

    Enum.filter(flights, fn tracked ->
      case tracked.flight_info do
        nil ->
          # Not yet enriched — keep it (will be filtered on enrichment arrival)
          true

        %FlightInfo{origin: origin, destination: destination} ->
          Enum.any?(airport_codes(origin) ++ airport_codes(destination), fn code -> code in normalized end)
      end
    end)
  end

  # ──────────────────────────────────────────────────── sorting & ranking ──

  @doc """
  Sort flights by distance from a location (closest first).
  Flights without position data sort last. Enriched flights break ties.
  """
  def sort_by_distance(flights, lat, lon) when is_number(lat) and is_number(lon) do
    Enum.sort_by(flights, fn tracked ->
      sv = tracked.state_vector

      distance =
        if is_number(sv.latitude) and is_number(sv.longitude) do
          Geo.haversine_km(lat, lon, sv.latitude, sv.longitude)
        else
          999_999.0
        end

      enriched = if tracked.flight_info, do: 0, else: 1
      {distance, enriched}
    end)
  end

  # Fallback when location is not available — sort by recency.
  def sort_by_distance(flights, _lat, _lon) do
    sort_by_recency(flights)
  end

  @doc "Return the top N closest flights for nearby mode display."
  def top_nearby(flights, lat, lon, limit \\ @max_display_flights) do
    flights
    |> sort_by_distance(lat, lon)
    |> Enum.take(limit)
  end

  @doc "Return the top N flights sorted by recency (enriched first, then most recent)."
  def top_by_recency(flights, limit \\ @max_display_flights) do
    flights
    |> sort_by_recency()
    |> Enum.take(limit)
  end

  # ────────────────────────────────────────────── callsign matching ──

  @doc "Case-insensitive exact match between a callsign and a tracked entry."
  def callsign_matches?(nil, _), do: false

  def callsign_matches?(callsign, tracked_entry) do
    String.downcase(callsign) == String.downcase(tracked_entry)
  end

  @doc "Returns true when the callsign appears in the tracked list."
  def in_tracked_list?(callsign, tracked_list) do
    Enum.any?(tracked_list, &callsign_matches?(callsign, &1))
  end

  # ──────────────────────────────────────────────────── private helpers ──

  defp reject_grounded(flights) do
    Enum.reject(flights, fn tracked -> tracked.state_vector.on_ground end)
  end

  defp sort_by_recency(flights) do
    Enum.sort_by(flights, fn tracked ->
      enriched = if tracked.flight_info, do: 0, else: 1
      last_seen = DateTime.to_unix(tracked.last_seen_at)
      {enriched, -last_seen}
    end)
  end

  # Extract all non-nil airport codes (IATA + ICAO) from an Airport struct.
  defp airport_codes(nil), do: []

  defp airport_codes(airport) do
    [airport.iata, airport.icao]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end
end
