defmodule AeroVision.Flight.Tracker do
  @moduledoc """
  Aggregates flight data from Skylink (raw ADS-B and enrichment).

  Subscribes to PubSub topics:
  - "flights" for `{:flights_raw, [%StateVector{}]}` and `{:flight_enriched, ...}`
  - "config"  for display mode / filter changes

  Maintains a map of currently tracked flights, applies configured filters,
  and broadcasts `{:display_flights, [%TrackedFlight{}]}` on the "display"
  PubSub topic whenever data changes.

  Filtering, sorting, and ranking are handled by `AeroVision.Flight.Filters`.
  Progress calculation by `AeroVision.Flight.Progress`.
  Enrichment policy by `AeroVision.Flight.Enrichment`.

  Stale flights (not seen in 2 minutes) are pruned every 30 seconds.
  """

  use GenServer

  alias AeroVision.Cache
  alias AeroVision.Config.Store
  alias AeroVision.Flight.Enrichment
  alias AeroVision.Flight.Filters
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightStatus
  alias AeroVision.Flight.Progress
  alias AeroVision.Flight.StateVector
  alias AeroVision.Flight.TrackedFlight

  require Logger

  @pubsub AeroVision.PubSub
  @flights_topic "flights"
  @display_topic "display"
  @config_topic "config"

  @cleanup_interval_ms 30_000
  @stale_threshold_sec 120
  @cache :tracker_cache
  @cache_key :last_flights

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
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @flights_topic)
    Phoenix.PubSub.subscribe(@pubsub, @config_topic)

    cached_flights =
      case Cache.get(@cache, @cache_key) do
        {flights, _cached_at} when is_map(flights) ->
          if map_size(flights) > 0 do
            Logger.info("[Tracker] Restored #{map_size(flights)} flight(s) from cache")
          end

          flights

        _ ->
          %{}
      end

    state = %{
      flights: cached_flights,
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
    broadcast_display(state)
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────── call handlers ──

  @impl true
  def handle_call(:get_flights, _from, state) do
    {:reply, Filters.filtered_flights(state), state}
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
    persist_and_broadcast(new_state)
    {:noreply, new_state}
  end

  # ──────────────────────────────────────────────────── flights_raw handler ──

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
                tracked = %TrackedFlight{
                  state_vector: sv,
                  flight_info: FlightStatus.get_cached(callsign),
                  first_seen_at: now,
                  last_seen_at: now
                }

                Map.put(acc, callsign, tracked)

              existing ->
                updated = %{
                  existing
                  | state_vector: sv,
                    last_seen_at: now,
                    flight_info: Progress.refresh(existing.flight_info, sv)
                }

                Map.put(acc, callsign, updated)
            end
        end
      end)

    new_flights =
      if state.mode == :tracked do
        Enrichment.inject_missing_tracked(new_flights, state, now)
      else
        new_flights
      end

    new_state = %{state | flights: new_flights}
    Enrichment.enrich_candidates(new_state)
    persist_and_broadcast(new_state)
    {:noreply, new_state}
  end

  # ────────────────────────────────────────────── flight_enriched handler ──

  @impl true
  def handle_info({:flight_enriched, callsign, %FlightInfo{} = info}, state) do
    case Map.get(state.flights, callsign) do
      nil ->
        if state.mode == :tracked and
             Filters.in_tracked_list?(callsign, state.tracked_flights) do
          now = DateTime.utc_now()
          enriched_info = %{info | progress_pct: Progress.calculate(nil, info)}

          tracked = %TrackedFlight{
            state_vector: %StateVector{callsign: callsign},
            flight_info: enriched_info,
            first_seen_at: now,
            last_seen_at: now
          }

          new_state = %{state | flights: Map.put(state.flights, callsign, tracked)}
          persist_and_broadcast(new_state)
          {:noreply, new_state}
        else
          {:noreply, state}
        end

      tracked ->
        enriched_info = %{info | progress_pct: Progress.calculate(tracked.state_vector, info)}
        updated = %{tracked | flight_info: enriched_info}
        new_state = %{state | flights: Map.put(state.flights, callsign, updated)}
        persist_and_broadcast(new_state)
        {:noreply, new_state}
    end
  end

  # ──────────────────────────────────────────── config_changed handlers ──

  @impl true
  def handle_info({:config_changed, key, _value}, state) when key in [:location_lat, :location_lon, :radius_km] do
    if state.mode == :nearby do
      Logger.info("[Tracker] Location changed, clearing flight state")

      new_state = %{
        state
        | flights: %{},
          location_lat: Store.get(:location_lat),
          location_lon: Store.get(:location_lon)
      }

      persist_and_broadcast(new_state)
      {:noreply, new_state}
    else
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
    Enrichment.enrich_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :tracked_flights, value}, state) do
    new_state = %{state | tracked_flights: value}

    new_state =
      if new_state.mode == :tracked do
        now = DateTime.utc_now()
        new_flights = Enrichment.inject_missing_tracked(new_state.flights, new_state, now)
        updated = %{new_state | flights: new_flights}
        Cache.put(@cache, @cache_key, new_flights)
        updated
      else
        new_state
      end

    Enrichment.enrich_candidates(new_state)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :airline_filters, value}, state) do
    new_state = Enrichment.merge_cached(%{state | airline_filters: value})
    Enrichment.enrich_candidates(new_state)
    persist_and_broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :airport_filters, value}, state) do
    new_state = Enrichment.merge_cached(%{state | airport_filters: value})
    Enrichment.enrich_candidates(new_state)
    persist_and_broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  # ──────────────────────────────────────────────────── cleanup handler ──

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_threshold_sec, :second)

    active_flights =
      Map.filter(state.flights, fn {callsign, tracked} ->
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
      persist_and_broadcast(new_state)
    end

    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ──────────────────────────────────────────────────── private helpers ──

  # Returns true when the callsign is in the user's tracked list.
  defp explicitly_tracked?(callsign, %{mode: :tracked, tracked_flights: [_ | _] = list}),
    do: Filters.in_tracked_list?(callsign, list)

  defp explicitly_tracked?(_callsign, _state), do: false

  # Persist the current flights map to the cache and broadcast to display.
  defp persist_and_broadcast(state) do
    Cache.put(@cache, @cache_key, state.flights)
    broadcast_display(state)
  end

  defp broadcast_display(state) do
    flights = Filters.filtered_flights(state)
    Phoenix.PubSub.broadcast(@pubsub, @display_topic, {:display_flights, flights})
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
