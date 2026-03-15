defmodule AeroVision.Flight.Tracker do
  @moduledoc """
  Aggregates flight data from OpenSky (raw ADS-B) and AeroAPI (enrichment).

  Subscribes to PubSub topics:
  - "flights" for `{:flights_raw, [%StateVector{}]}` and `{:flight_enriched, ...}`
  - "config"  for display mode / filter changes

  Maintains a map of currently tracked flights, applies configured filters,
  and broadcasts `{:display_flights, [%TrackedFlight{}]}` on the "display"
  PubSub topic whenever data changes.

  Stale flights (not seen in 2 minutes) are pruned every 30 seconds.
  """

  use GenServer
  require Logger

  alias AeroVision.Config.Store
  alias AeroVision.Flight.{AeroAPI, TrackedFlight, FlightInfo}

  @pubsub AeroVision.PubSub
  @flights_topic "flights"
  @display_topic "display"
  @config_topic "config"

  @cleanup_interval_ms 30_000
  @stale_threshold_sec 120
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

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @flights_topic)
    Phoenix.PubSub.subscribe(@pubsub, @config_topic)

    data_dir =
      if Application.get_env(:aerovision, :target, :host) == :host do
        Path.join(System.user_home!(), ".aerovision/tracker_cache")
      else
        "/data/aerovision/tracker_cache"
      end

    File.mkdir_p!(data_dir)

    db =
      case CubDB.start_link(
             data_dir: data_dir,
             name: :aerovision_tracker_cache,
             # Compact aggressively — we write one key repeatedly every 15s,
             # so the append-only file accumulates dirt quickly.
             auto_compact: {10, 0.3}
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    # Restore last known flights from cache
    cached_flights = CubDB.get(db, @cache_key, %{})
    flight_count = map_size(cached_flights)

    if flight_count > 0 do
      Logger.info("[Tracker] Restored #{flight_count} flight(s) from cache")
    end

    state = %{
      flights: cached_flights,
      db: db,
      mode: Store.get(:display_mode),
      tracked_flights: Store.get(:tracked_flights),
      airline_filters: Store.get(:airline_filters),
      cleanup_timer: nil
    }

    cleanup_timer = schedule_cleanup()
    {:ok, %{state | cleanup_timer: cleanup_timer}, {:continue, :broadcast_initial}}
  end

  @impl true
  def handle_continue(:broadcast_initial, state) do
    # Broadcast cached flights immediately so any already-connected LiveViews
    # receive current state without waiting for the first OpenSky poll
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
                # New flight — request enrichment only if it passes the active filter
                if should_enrich?(callsign, state) do
                  AeroAPI.enrich(callsign)
                end

                tracked = %TrackedFlight{
                  state_vector: sv,
                  flight_info: AeroAPI.get_cached(callsign),
                  first_seen_at: now,
                  last_seen_at: now
                }

                Map.put(acc, callsign, tracked)

              existing ->
                # Known flight — update position data
                updated = %{existing | state_vector: sv, last_seen_at: now}
                Map.put(acc, callsign, updated)
            end
        end
      end)

    new_state = %{state | flights: new_flights}
    CubDB.put(new_state.db, @cache_key, new_flights)
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:flight_enriched, callsign, %FlightInfo{} = info}, state) do
    case Map.get(state.flights, callsign) do
      nil ->
        {:noreply, state}

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
  def handle_info({:config_changed, :display_mode, value}, state) do
    new_state = %{state | mode: value}
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :tracked_flights, value}, state) do
    new_state = %{state | tracked_flights: value}
    broadcast_display(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:config_changed, :airline_filters, value}, state) do
    new_state = %{state | airline_filters: value}
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
      Map.filter(state.flights, fn {_callsign, tracked} ->
        DateTime.compare(tracked.last_seen_at, cutoff) == :gt
      end)

    pruned = map_size(state.flights) - map_size(active_flights)

    if pruned > 0 do
      Logger.debug("[Tracker] Pruned #{pruned} stale flight(s)")
    end

    cleanup_timer = schedule_cleanup()
    new_state = %{state | flights: active_flights, cleanup_timer: cleanup_timer}

    if map_size(new_state.flights) != map_size(state.flights) do
      CubDB.put(new_state.db, @cache_key, new_state.flights)
    end

    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ──────────────────────────────────────────────── enrichment gating ──

  # Only request AeroAPI enrichment for flights that will actually be displayed.
  # This keeps API usage proportional to what's on screen.

  defp should_enrich?(callsign, %{mode: :tracked, tracked_flights: tracked_list}) do
    Enum.any?(tracked_list, &callsign_matches?(callsign, &1))
  end

  defp should_enrich?(_callsign, %{mode: :nearby, airline_filters: []}), do: true

  defp should_enrich?(callsign, %{mode: :nearby, airline_filters: filters}) do
    Enum.any?(filters, &String.starts_with?(callsign, &1))
  end

  defp should_enrich?(_callsign, _state), do: true

  # ───────────────────────────────────────────────────────── filter logic ──

  defp filtered_flights(%{mode: :nearby, airline_filters: filters, flights: flights}) do
    flights
    |> Map.values()
    |> filter_by_airline(filters)
    |> Enum.sort_by(& &1.state_vector.callsign)
  end

  defp filtered_flights(%{mode: :tracked, tracked_flights: tracked_list, flights: flights}) do
    flights
    |> Map.values()
    |> Enum.filter(fn tracked ->
      callsign = tracked.state_vector.callsign
      Enum.any?(tracked_list, &callsign_matches?(callsign, &1))
    end)
    |> Enum.sort_by(& &1.state_vector.callsign)
  end

  # Fall-through for any unexpected modes
  defp filtered_flights(%{flights: flights}) do
    flights |> Map.values() |> Enum.sort_by(& &1.state_vector.callsign)
  end

  # Empty filter list → show everything
  defp filter_by_airline(flights, []), do: flights

  defp filter_by_airline(flights, filters) do
    Enum.filter(flights, fn tracked ->
      callsign = tracked.state_vector.callsign || ""
      Enum.any?(filters, &String.starts_with?(callsign, &1))
    end)
  end

  # Case-insensitive prefix match (e.g. "AAL1234" matches tracked entry "AAL1234")
  defp callsign_matches?(nil, _), do: false

  defp callsign_matches?(callsign, tracked_entry) do
    String.downcase(callsign) == String.downcase(tracked_entry)
  end

  # ──────────────────────────────────────────────────── progress calculation ──

  # Calculate flight progress (0.0–1.0) from departure and arrival times.
  # Prefers actual_departure_time over scheduled for accuracy when the flight
  # departed late. Falls back to nil if times are unavailable.
  defp calculate_progress(_sv, %FlightInfo{arrival_time: nil}), do: nil

  defp calculate_progress(_sv, %FlightInfo{departure_time: nil, actual_departure_time: nil}),
    do: nil

  defp calculate_progress(_sv, info) do
    now = DateTime.utc_now()

    depart = info.actual_departure_time || info.departure_time
    arrive = info.arrival_time

    dep_unix = DateTime.to_unix(depart)
    arr_unix = DateTime.to_unix(arrive)
    now_unix = DateTime.to_unix(now)

    total = arr_unix - dep_unix

    if total <= 0 do
      nil
    else
      ((now_unix - dep_unix) / total)
      |> max(0.0)
      |> min(1.0)
    end
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
