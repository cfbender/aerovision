defmodule AeroVision.Flight.Enrichment do
  @moduledoc """
  Enrichment policy for tracked flights.

  Decides which flights need enrichment data, when to refresh stale data,
  and manages synthetic entries for tracked flights without ADS-B coverage.
  """

  alias AeroVision.Flight.Filters
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightStatus
  alias AeroVision.Flight.Progress
  alias AeroVision.Flight.StateVector
  alias AeroVision.Flight.TrackedFlight

  require Logger

  # @max_display_flights + 2 buffer — only the closest N flights are enriched in nearby mode
  @enrich_candidates 5

  # ─────────────────────────────────────────── top-level enrichment entry ──

  @doc """
  Request enrichment for the top flight candidates based on the current mode.

  In nearby mode, only the closest N unenriched flights are enriched.
  In tracked mode, all unenriched tracked flights are enriched and stale
  ones are refreshed.
  """
  def enrich_candidates(%{mode: :nearby} = state) do
    candidates = nearby_candidates(state)

    Enum.each(candidates, fn tracked ->
      callsign = tracked.state_vector.callsign

      if callsign && is_nil(tracked.flight_info) do
        FlightStatus.enrich(callsign)
      end
    end)
  end

  def enrich_candidates(state) do
    request_missing(state)
    refresh_stale(state)
  end

  # ──────────────────────────────────────── merge cached enrichment data ──

  @doc """
  Pull cached FlightInfo into any tracked flights that are missing enrichment.

  Called synchronously when filter config changes so the new filter can act
  on cached data immediately, without waiting for the next poll tick.
  """
  def merge_cached(state) do
    updated_flights =
      Map.new(state.flights, fn {callsign, tracked} ->
        cond do
          tracked.flight_info != nil ->
            {callsign, tracked}

          is_nil(callsign) ->
            {callsign, tracked}

          true ->
            case FlightStatus.get_cached(callsign) do
              nil ->
                {callsign, tracked}

              %FlightInfo{} = info ->
                progress = Progress.calculate(tracked.state_vector, info)
                enriched = %{info | progress_pct: progress}
                {callsign, %{tracked | flight_info: enriched}}
            end
        end
      end)

    %{state | flights: updated_flights}
  end

  # ────────────────────────────────────── synthetic tracked flight entries ──

  @doc """
  Ensure every tracked callsign has an entry in the flights map.

  For callsigns without ADS-B data, creates a synthetic TrackedFlight with nil
  telemetry. For existing entries, refreshes last_seen_at to prevent stale pruning.
  """
  def inject_missing_tracked(flights, state, now) do
    Enum.reduce(state.tracked_flights, flights, fn tracked_entry, acc ->
      match = Enum.find(acc, fn {cs, _} -> Filters.callsign_matches?(cs, tracked_entry) end)

      case match do
        {cs, existing} ->
          # Tracked flight (real or synthetic) — refresh last_seen_at and
          # recalculate progress so it advances on every poll tick
          updated = %{
            existing
            | last_seen_at: now,
              flight_info: Progress.refresh(existing.flight_info, existing.state_vector)
          }

          Map.put(acc, cs, updated)

        nil ->
          # Not in flights at all — create synthetic entry
          callsign = String.upcase(tracked_entry)
          cached_info = FlightStatus.get_cached(callsign)
          if is_nil(cached_info), do: FlightStatus.enrich(callsign)

          synthetic = %TrackedFlight{
            state_vector: %StateVector{callsign: callsign},
            flight_info: cached_info,
            first_seen_at: now,
            last_seen_at: now
          }

          Map.put(acc, callsign, synthetic)
      end
    end)
  end

  # ──────────────────────────────────────────────── private helpers ──

  # In tracked mode, re-enrich displayed flights whose enrichment data
  # is older than the refresh TTL (~30 min). Skips landed/cancelled flights.
  defp refresh_stale(%{mode: :tracked, flights: flights, tracked_flights: tracked_list}) do
    flights
    |> Map.keys()
    |> Enum.each(fn callsign ->
      tracked = Map.get(flights, callsign)

      if tracked && tracked.flight_info &&
           not terminal_status?(tracked.flight_info.status) &&
           Filters.in_tracked_list?(callsign, tracked_list) &&
           FlightStatus.needs_refresh?(callsign) do
        Logger.debug("[Enrichment] Refreshing stale enrichment for tracked flight #{callsign}")
        FlightStatus.re_enrich(callsign)
      end
    end)
  end

  # Non-tracked modes don't need periodic refresh.
  defp refresh_stale(_state), do: :ok

  # For each flight that passes the active filter but has no enrichment, request it.
  defp request_missing(state) do
    state.flights
    |> Map.values()
    |> Enum.each(fn tracked ->
      callsign = tracked.state_vector.callsign

      if callsign && is_nil(tracked.flight_info) && should_enrich?(callsign, state) do
        FlightStatus.enrich(callsign)
      end
    end)
  end

  # Select the top @enrich_candidates closest flights as enrichment candidates.
  defp nearby_candidates(%{
         mode: :nearby,
         airline_filters: airline_filters,
         flights: flights,
         location_lat: lat,
         location_lon: lon
       }) do
    flights
    |> Map.values()
    |> Filters.by_airline(airline_filters)
    |> Filters.sort_by_distance(lat, lon)
    |> Enum.take(@enrich_candidates)
  end

  defp should_enrich?(callsign, %{mode: :tracked, tracked_flights: tracked_list}) do
    Filters.in_tracked_list?(callsign, tracked_list)
  end

  # If airport filters are active in nearby mode, we must enrich ALL flights
  # because airport data only comes from enrichment — we can't pre-filter.
  defp should_enrich?(_callsign, %{mode: :nearby, airport_filters: [_ | _]}), do: true

  defp should_enrich?(_callsign, %{mode: :nearby, airline_filters: []}), do: true

  defp should_enrich?(callsign, %{mode: :nearby, airline_filters: filters}) do
    Enum.any?(filters, &String.starts_with?(callsign, &1))
  end

  defp should_enrich?(_callsign, _state), do: true

  # Flights in terminal states don't need periodic refresh.
  defp terminal_status?("Landed"), do: true
  defp terminal_status?("Cancelled"), do: true
  defp terminal_status?(_), do: false
end
