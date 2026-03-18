defmodule AeroVision.Flight.Tracker do
  @moduledoc """
  Aggregates flight data from Skylink (raw ADS-B and enrichment).

  Subscribes to PubSub topics:
  - "flights" for `{:flights_raw, [%StateVector{}]}` and `{:flight_enriched, ...}`
  - "config"  for display mode / filter changes

  Maintains a map of currently tracked flights, applies configured filters,
  and broadcasts `{:display_flights, [%TrackedFlight{}]}` on the "display"
  PubSub topic whenever data changes.

  Stale flights (not seen in 2 minutes) are pruned every 30 seconds.
  """

  use GenServer

  alias AeroVision.Config.Store
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightStatus
  alias AeroVision.Flight.StateVector
  alias AeroVision.Flight.TrackedFlight
  alias AeroVision.Flight.Utils.Geo

  require Logger

  @pubsub AeroVision.PubSub
  @flights_topic "flights"
  @display_topic "display"
  @config_topic "config"

  @cleanup_interval_ms 30_000
  @stale_threshold_sec 120
  @cache_key :last_flights
  # Must match the same constant in Renderer — no flight shorter than this is valid
  @min_flight_duration_sec 15 * 60
  # Bump whenever TrackedFlight or FlightInfo struct fields change so stale
  # serialized structs (missing new fields) don't crash on access after a deploy.
  @cache_version 2

  @max_display_flights 3
  # @max_display_flights + 2 buffer — only the closest N flights are enriched in nearby mode
  @enrich_candidates 5

  # ─────────────────────────────────────────────────────────── public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current filtered list of tracked flights."
  def get_flights do
    GenServer.call(__MODULE__, :get_flights)
  end

  @doc "Returns a specific flight by callsign, or nil if not found."
  def get_flight(callsign) when is_binary(callsign) do
    GenServer.call(__MODULE__, {:get_flight, callsign})
  end

  @doc "Trigger an immediate broadcast of the current flight state."
  def broadcast_now do
    GenServer.cast(__MODULE__, :broadcast_now)
  end

  @doc "Clears all tracked flights. They will repopulate on the next ADS-B poll cycle."
  def clear_flights do
    GenServer.cast(__MODULE__, :clear_flights)
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(@pubsub, @flights_topic)
    Phoenix.PubSub.subscribe(@pubsub, @config_topic)

    data_dir =
      Keyword.get(opts, :data_dir) ||
        case Application.get_env(:aerovision, :target, :host) do
          target when target in [:host, :test] ->
            Path.join(System.user_home!(), ".aerovision/tracker_cache")

          _ ->
            "/data/aerovision/tracker_cache"
        end

    File.mkdir_p!(data_dir)

    # Use a named CubDB only when no custom data_dir was provided (i.e. normal
    # startup). In tests, each test passes its own data_dir and we must NOT
    # share the named table or subsequent start_supervised! calls would get the
    # old process back via :already_started.
    db_base_opts =
      if Keyword.has_key?(opts, :data_dir) do
        [data_dir: data_dir]
      else
        [data_dir: data_dir, name: :aerovision_tracker_cache]
      end

    db =
      AeroVision.DB.open(
        db_base_opts ++
          [
            # Compact aggressively — we write one key repeatedly every 15s,
            # so the append-only file accumulates dirt quickly.
            auto_compact: {10, 0.3}
          ]
      )

    # Check cache version — clear flights if the TrackedFlight/FlightInfo struct
    # layout has changed since the last deploy. Accessing missing fields on a
    # stale deserialized struct raises KeyError and crashes the GenServer.
    stored_version = CubDB.get(db, :cache_version, 0)

    cached_flights =
      if stored_version < @cache_version do
        Logger.info("[Tracker] Cache version #{stored_version} < #{@cache_version} — clearing stale flight data")

        CubDB.put(db, :cache_version, @cache_version)
        CubDB.delete(db, @cache_key)
        %{}
      else
        flights = CubDB.get(db, @cache_key, %{})

        if map_size(flights) > 0 do
          Logger.info("[Tracker] Restored #{map_size(flights)} flight(s) from cache")
        end

        flights
      end

    state = %{
      flights: cached_flights,
      db: db,
      mode: Store.get(:display_mode),
      tracked_flights: Store.get(:tracked_flights),
      airline_filters: Store.get(:airline_filters),
      airport_filters: Store.get(:airport_filters),
      location_lat: Store.get(:location_lat),
      location_lon: Store.get(:location_lon),
      cleanup_timer: nil
    }

    cleanup_timer = schedule_cleanup()
    {:ok, %{state | cleanup_timer: cleanup_timer}, {:continue, :broadcast_initial}}
  end

  @impl true
  def handle_continue(:broadcast_initial, state) do
    # Broadcast cached flights immediately so any already-connected LiveViews
    # receive current state without waiting for the first Skylink poll
    broadcast_display(state)
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────── call handlers ──

  @impl true
  def handle_call(:get_flights, _from, state) do
    {:reply, filtered_flights(state), state}
  end

  @impl true
  def handle_call({:get_flight, callsign}, _from, state) do
    {:reply, Map.get(state.flights, callsign), state}
  end

  # ─────────────────────────────────────────────────────── cast handlers ──

  @impl true
  def handle_cast(:broadcast_now, state) do
    broadcast_display(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear_flights, state) do
    Logger.info("[Tracker] All flights cleared by user request")
    new_state = %{state | flights: %{}}
    CubDB.put(new_state.db, @cache_key, %{})
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  # ──────────────────────────────────────────────────────── info handlers ──

  @impl true
  def handle_info({:flights_raw, vectors}, state) do
    now = DateTime.utc_now()

    new_flights =
      Enum.reduce(vectors, state.flights, fn sv, acc ->
        case sv.callsign do
          nil ->
            acc

          callsign ->
            case Map.get(acc, callsign) do
              nil ->
                # New flight — just store it; enrich_top_candidates/1 will
                # selectively request enrichment after the reduce completes.
                tracked = %TrackedFlight{
                  state_vector: sv,
                  flight_info: FlightStatus.get_cached(callsign),
                  first_seen_at: now,
                  last_seen_at: now
                }

                Map.put(acc, callsign, tracked)

              existing ->
                # Known flight — update position data and recalculate progress
                updated = %{
                  existing
                  | state_vector: sv,
                    last_seen_at: now,
                    flight_info: refresh_progress(existing.flight_info, sv)
                }

                Map.put(acc, callsign, updated)
            end
        end
      end)

    # In tracked mode, create/refresh synthetic entries for tracked callsigns
    # not found in ADS-B data (e.g., flights over oceans without coverage)
    new_flights =
      if state.mode == :tracked do
        inject_missing_tracked(new_flights, state, now)
      else
        new_flights
      end

    new_state = %{state | flights: new_flights}
    CubDB.put(new_state.db, @cache_key, new_flights)
    enrich_top_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:flight_enriched, callsign, %FlightInfo{} = info}, state) do
    case Map.get(state.flights, callsign) do
      nil ->
        # In tracked mode, create a synthetic entry if this callsign is tracked
        if state.mode == :tracked and
             Enum.any?(state.tracked_flights, &callsign_matches?(callsign, &1)) do
          now = DateTime.utc_now()
          progress = calculate_progress(nil, info)
          enriched_info = %{info | progress_pct: progress}

          tracked = %TrackedFlight{
            state_vector: %StateVector{callsign: callsign},
            flight_info: enriched_info,
            first_seen_at: now,
            last_seen_at: now
          }

          new_flights = Map.put(state.flights, callsign, tracked)
          new_state = %{state | flights: new_flights}
          CubDB.put(new_state.db, @cache_key, new_flights)
          broadcast_display(new_state)
          {:noreply, new_state}
        else
          {:noreply, state}
        end

      tracked ->
        progress = calculate_progress(tracked.state_vector, info)

        enriched_info = %{info | progress_pct: progress}
        updated = %{tracked | flight_info: enriched_info}
        new_flights = Map.put(state.flights, callsign, updated)
        new_state = %{state | flights: new_flights}
        CubDB.put(new_state.db, @cache_key, new_state.flights)
        broadcast_display(new_state)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:config_changed, key, _value}, state) when key in [:location_lat, :location_lon, :radius_km] do
    if state.mode == :nearby do
      # Location changed — clear all flights immediately. Old location's planes
      # are irrelevant. The next SkyLink broadcast will repopulate with fresh data.
      Logger.info("[Tracker] Location changed, clearing flight state")

      new_state = %{
        state
        | flights: %{},
          location_lat: Store.get(:location_lat),
          location_lon: Store.get(:location_lon)
      }

      CubDB.put(new_state.db, @cache_key, %{})
      broadcast_display(new_state)
      {:noreply, new_state}
    else
      # In tracked/other modes, keep flight state intact but update stored coords
      {:noreply,
       %{
         state
         | location_lat: Store.get(:location_lat),
           location_lon: Store.get(:location_lon)
       }}
    end
  end

  @impl true
  def handle_info({:config_changed, :display_mode, value}, state) do
    new_state = %{state | mode: value}
    enrich_top_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :tracked_flights, value}, state) do
    new_state = %{state | tracked_flights: value}

    # In tracked mode, create synthetic entries for new callsigns immediately
    new_state =
      if new_state.mode == :tracked do
        now = DateTime.utc_now()
        new_flights = inject_missing_tracked(new_state.flights, new_state, now)
        updated = %{new_state | flights: new_flights}
        # Persist immediately so synthetic entries survive a Tracker restart
        # before the next ADS-B poll cycle writes the cache.
        CubDB.put(updated.db, @cache_key, new_flights)
        updated
      else
        new_state
      end

    enrich_top_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :airline_filters, value}, state) do
    new_state = merge_cached_enrichment(%{state | airline_filters: value})

    CubDB.put(new_state.db, @cache_key, new_state.flights)
    enrich_top_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :airport_filters, value}, state) do
    # Pull cached enrichment data from ETS into state immediately so the
    # airport filter can act on it right now, without waiting for the
    # next Skylink tick.
    new_state = merge_cached_enrichment(%{state | airport_filters: value})

    CubDB.put(new_state.db, @cache_key, new_state.flights)
    enrich_top_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_threshold_sec, :second)

    active_flights =
      Map.filter(state.flights, fn {callsign, tracked} ->
        # Explicitly-tracked flights are never pruned — the user asked for them
        # permanently, regardless of ADS-B coverage or poll hiccups.
        explicitly_tracked?(callsign, state) or
          DateTime.after?(tracked.last_seen_at, cutoff)
      end)

    pruned = map_size(state.flights) - map_size(active_flights)

    if pruned > 0 do
      Logger.info("[Tracker] Pruned #{pruned} stale flight(s)")
    end

    cleanup_timer = schedule_cleanup()
    new_state = %{state | flights: active_flights, cleanup_timer: cleanup_timer}

    if map_size(new_state.flights) != map_size(state.flights) do
      CubDB.put(new_state.db, @cache_key, new_state.flights)
      broadcast_display(new_state)
    end

    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ──────────────────────────────────────────────── enrichment gating ──

  # Pull cached FlightInfo from the Skylink ETS table into any tracked flights
  # that are missing enrichment. This is called synchronously when filter
  # config changes so the new filter can act on cached data immediately,
  # without waiting for the next Skylink tick.
  # For cache misses, queues an enrichment request as usual.
  defp merge_cached_enrichment(state) do
    updated_flights =
      Map.new(state.flights, fn {callsign, tracked} ->
        cond do
          tracked.flight_info != nil ->
            # Already enriched — nothing to do
            {callsign, tracked}

          is_nil(callsign) ->
            {callsign, tracked}

          true ->
            case FlightStatus.get_cached(callsign) do
              nil ->
                # Not in cache — enrich_top_candidates/1 will handle requests
                {callsign, tracked}

              %FlightInfo{} = info ->
                progress = calculate_progress(tracked.state_vector, info)
                enriched = %{info | progress_pct: progress}
                {callsign, %{tracked | flight_info: enriched}}
            end
        end
      end)

    %{state | flights: updated_flights}
  end

  # In tracked mode, ensure every tracked callsign has an entry in the flights map.
  # For callsigns without ADS-B data, creates a synthetic TrackedFlight with nil
  # telemetry. For existing synthetic entries, refreshes last_seen_at to prevent
  # stale pruning.
  defp inject_missing_tracked(flights, state, now) do
    Enum.reduce(state.tracked_flights, flights, fn tracked_entry, acc ->
      match = Enum.find(acc, fn {cs, _} -> callsign_matches?(cs, tracked_entry) end)

      case match do
        {cs, existing} ->
          # Tracked flight (real or synthetic) — refresh last_seen_at and
          # recalculate progress so it advances on every poll tick
          updated = %{
            existing
            | last_seen_at: now,
              flight_info: refresh_progress(existing.flight_info, existing.state_vector)
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

  # For each flight currently in state that passes the active filter but has no
  # enrichment, request Skylink enrichment. Called after filter config changes.
  defp request_missing_enrichment(state) do
    state.flights
    |> Map.values()
    |> Enum.each(fn tracked ->
      callsign = tracked.state_vector.callsign

      if callsign && is_nil(tracked.flight_info) && should_enrich?(callsign, state) do
        FlightStatus.enrich(callsign)
      end
    end)
  end

  # In tracked mode, re-enrich displayed flights whose enrichment data
  # is older than the refresh TTL (~30 min). Skips landed/cancelled flights.
  defp refresh_stale_tracked(%{mode: :tracked, flights: flights, tracked_flights: tracked_list}) do
    flights
    |> Map.keys()
    |> Enum.each(fn callsign ->
      tracked = Map.get(flights, callsign)

      if tracked && tracked.flight_info &&
           not terminal_status?(tracked.flight_info.status) &&
           Enum.any?(tracked_list, &callsign_matches?(callsign, &1)) &&
           FlightStatus.needs_refresh?(callsign) do
        Logger.debug("[Tracker] Refreshing stale enrichment for tracked flight #{callsign}")
        FlightStatus.re_enrich(callsign)
      end
    end)
  end

  # Non-tracked modes don't need periodic refresh.
  defp refresh_stale_tracked(_state), do: :ok

  # Flights in terminal states don't need periodic refresh.
  defp terminal_status?("Landed"), do: true
  defp terminal_status?("Cancelled"), do: true
  defp terminal_status?(_), do: false

  # In nearby mode, only request enrichment for the closest @enrich_candidates flights.
  # This prevents enriching dozens of flights when only @max_display_flights are displayed.
  defp enrich_top_candidates(%{mode: :nearby} = state) do
    candidates = enrichment_candidates(state)

    Enum.each(candidates, fn tracked ->
      callsign = tracked.state_vector.callsign

      if callsign && is_nil(tracked.flight_info) do
        FlightStatus.enrich(callsign)
      end
    end)
  end

  # For tracked mode: enrich missing flights AND refresh stale ones.
  defp enrich_top_candidates(state) do
    request_missing_enrichment(state)
    refresh_stale_tracked(state)
  end

  # Select the top @enrich_candidates closest flights as enrichment candidates.
  # Uses the same distance-based sorting as display selection.
  # Applies airline_filters (same as display) but NOT airport_filters — because
  # airport data requires enrichment to be available.
  defp enrichment_candidates(%{
         mode: :nearby,
         airline_filters: airline_filters,
         flights: flights,
         location_lat: lat,
         location_lon: lon
       }) do
    flights
    |> Map.values()
    |> filter_by_airline(airline_filters)
    |> sort_by_distance(lat, lon)
    |> Enum.take(@enrich_candidates)
  end

  defp should_enrich?(callsign, %{mode: :tracked, tracked_flights: tracked_list}) do
    Enum.any?(tracked_list, &callsign_matches?(callsign, &1))
  end

  # If airport filters are active in nearby mode, we must enrich ALL flights
  # because airport data only comes from enrichment — we can't pre-filter.
  defp should_enrich?(_callsign, %{mode: :nearby, airport_filters: [_ | _]}), do: true

  defp should_enrich?(_callsign, %{mode: :nearby, airline_filters: []}), do: true

  defp should_enrich?(callsign, %{mode: :nearby, airline_filters: filters}) do
    Enum.any?(filters, &String.starts_with?(callsign, &1))
  end

  defp should_enrich?(_callsign, _state), do: true

  # ───────────────────────────────────────────────────────── filter logic ──

  defp filtered_flights(%{
         mode: :nearby,
         airline_filters: airline_filters,
         airport_filters: airport_filters,
         flights: flights,
         location_lat: lat,
         location_lon: lon
       }) do
    flights
    |> Map.values()
    |> filter_by_airline(airline_filters)
    |> filter_by_airport(airport_filters)
    |> top_flights(lat, lon)
  end

  defp filtered_flights(%{mode: :tracked, tracked_flights: tracked_list, flights: flights}) do
    flights
    |> Map.values()
    |> Enum.filter(fn tracked ->
      callsign = tracked.state_vector.callsign
      Enum.any?(tracked_list, &callsign_matches?(callsign, &1))
    end)
    |> top_flights()
  end

  # Fall-through for any unexpected modes
  defp filtered_flights(%{flights: flights}) do
    flights |> Map.values() |> top_flights()
  end

  # Sort flights by distance from user location (closest first).
  # Flights without position data sort last. Enriched flights break ties.
  defp sort_by_distance(flights, lat, lon) when is_number(lat) and is_number(lon) do
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
  defp sort_by_distance(flights, _lat, _lon) do
    Enum.sort_by(flights, fn tracked ->
      enriched = if tracked.flight_info, do: 0, else: 1
      last_seen = DateTime.to_unix(tracked.last_seen_at)
      {enriched, -last_seen}
    end)
  end

  defp top_flights(flights, lat, lon) do
    flights
    |> sort_by_distance(lat, lon)
    |> Enum.take(@max_display_flights)
  end

  # Sort for tracked mode: enriched flights first, then by most recently seen.
  defp top_flights(flights) do
    flights
    |> sort_by_distance(nil, nil)
    |> Enum.take(@max_display_flights)
  end

  # Empty filter list → show everything
  defp filter_by_airline(flights, []), do: flights

  defp filter_by_airline(flights, filters) do
    Enum.filter(flights, fn tracked ->
      callsign = tracked.state_vector.callsign || ""
      Enum.any?(filters, &String.starts_with?(callsign, &1))
    end)
  end

  # Empty airport filter list → show everything
  defp filter_by_airport(flights, []), do: flights

  defp filter_by_airport(flights, filters) do
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

  # Extract all non-nil airport codes (IATA + ICAO) from an Airport struct.
  defp airport_codes(nil), do: []

  defp airport_codes(airport) do
    [airport.iata, airport.icao]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end

  # Case-insensitive prefix match (e.g. "AAL1234" matches tracked entry "AAL1234")
  defp callsign_matches?(nil, _), do: false

  defp callsign_matches?(callsign, tracked_entry) do
    String.downcase(callsign) == String.downcase(tracked_entry)
  end

  # Returns true when the callsign is in the user's tracked list (tracked mode only).
  defp explicitly_tracked?(callsign, %{mode: :tracked, tracked_flights: [_ | _] = list}),
    do: Enum.any?(list, &callsign_matches?(callsign, &1))

  defp explicitly_tracked?(_callsign, _state), do: false

  # ──────────────────────────────────────────────────── progress calculation ──

  # Calculate flight progress (0.0–1.0) from departure and arrival times.
  # Prefers actual_departure_time over scheduled for accuracy when the flight
  # departed late. Applies the same 15-minute sanity check as the renderer so
  # bad estimated_arrival_time values from the API don't collapse progress to 0.
  # Returns nil if any required time is unavailable or the data looks invalid.
  defp calculate_progress(_sv, info) do
    now = DateTime.utc_now()

    # Prefer most accurate departure time: actual > estimated > scheduled
    depart = info.actual_departure_time || info.estimated_departure_time || info.departure_time
    # Use validated arrival — rejects estimated values within 15 min of departure
    arrive = validated_arrival_time(info, depart)

    if is_nil(depart) or is_nil(arrive) do
      nil
    else
      dep_unix = DateTime.to_unix(depart)
      arr_unix = DateTime.to_unix(arrive)
      now_unix = DateTime.to_unix(now)
      total = arr_unix - dep_unix

      cond do
        # Arrival not meaningfully after departure — data is unusable
        total <= 0 -> nil
        # Flight hasn't departed yet
        now_unix < dep_unix -> nil
        true -> min((now_unix - dep_unix) / total, 1.0)
      end
    end
  end

  # Recomputes progress_pct on a FlightInfo, or returns nil as-is.
  defp refresh_progress(nil, _sv), do: nil
  defp refresh_progress(fi, sv), do: %{fi | progress_pct: calculate_progress(sv, fi)}

  # Mirror of Renderer.best_arrival_time/1 — rejects estimated arrival times
  # that are within @min_flight_duration_sec of departure (bad API data).
  defp validated_arrival_time(info, departure) do
    estimated = info.estimated_arrival_time

    estimated_valid? =
      not is_nil(estimated) and
        (is_nil(departure) or DateTime.diff(estimated, departure) > @min_flight_duration_sec)

    if estimated_valid?, do: estimated, else: info.arrival_time
  end

  # ──────────────────────────────────────────────────────── broadcast helper ──

  defp broadcast_display(state) do
    flights = filtered_flights(state)
    Phoenix.PubSub.broadcast(@pubsub, @display_topic, {:display_flights, flights})
  end

  # ──────────────────────────────────────────────────────────── scheduling ──

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
