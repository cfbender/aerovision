defmodule AeroVision.Flight.AeroAPI do
  @moduledoc """
  FlightAware AeroAPI v4 enrichment client.

  Fetches enriched flight data (origin/destination airports, aircraft type,
  airline name, departure/arrival times) for a given callsign and caches
  results in ETS for 24 hours.

  Incoming enrichment requests are queued and processed at a max rate of
  1 request per second to respect AeroAPI rate limits.

  Broadcasts `{:flight_enriched, callsign, %FlightInfo{}}` on PubSub topic
  "flights" when enrichment completes.

  Cache entries are persisted to CubDB so they survive reboots. Monthly API
  call counts are also tracked in CubDB to help stay within the free tier
  (~1,000 calls/month at $0.005 each).
  """

  use GenServer
  require Logger

  alias AeroVision.Config.Store
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Airport

  @pubsub AeroVision.PubSub
  @topic "flights"

  @cache_table :aerovision_aeroapi_cache
  @cache_ttl_sec 86_400
  @rate_limit_ms 1_000
  @persist_table :aerovision_aeroapi_persist

  # ─────────────────────────────────────────────────────────── public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request enrichment for a callsign. Returns immediately.
  Result will be broadcast as `{:flight_enriched, callsign, %FlightInfo{}}`.
  """
  def enrich(callsign) when is_binary(callsign) do
    GenServer.cast(__MODULE__, {:enrich, callsign})
    :ok
  end

  @doc "Returns the number of AeroAPI calls made this calendar month."
  def monthly_usage do
    GenServer.call(__MODULE__, :monthly_usage)
  end

  @doc "Synchronously look up a cached %FlightInfo{} by callsign, or nil."
  def get_cached(callsign) when is_binary(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, flight_info, cached_at}] when now - cached_at < @cache_ttl_sec ->
        flight_info

      _ ->
        nil
    end
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(_opts) do
    :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])

    data_dir =
      if Application.get_env(:aerovision, :target, :host) == :host do
        Path.join(System.user_home!(), ".aerovision/aeroapi_cache")
      else
        "/data/aerovision/aeroapi_cache"
      end

    File.mkdir_p!(data_dir)

    db =
      case CubDB.start_link(data_dir: data_dir, name: @persist_table) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    # Load valid cache entries into ETS and purge expired ones from CubDB
    now = System.system_time(:second)

    CubDB.select(db)
    |> Enum.each(fn
      {key, {flight_info, cached_at}} when is_binary(key) ->
        if now - cached_at < @cache_ttl_sec do
          :ets.insert(@cache_table, {key, flight_info, cached_at})
        else
          CubDB.delete(db, key)
        end

      _ ->
        :ok
    end)

    # Read monthly call count
    month_key = month_key()
    call_count = CubDB.get(db, {:calls, month_key}, 0)

    state = %{
      queue: MapSet.new(),
      timer: nil,
      db: db,
      call_count: call_count,
      month_key: month_key
    }

    timer = schedule_tick()
    schedule_prune()
    {:ok, %{state | timer: timer}}
  end

  @impl true
  def handle_call(:monthly_usage, _from, state) do
    {:reply, state.call_count, state}
  end

  @impl true
  def handle_cast({:enrich, callsign}, state) do
    # Skip if already cached with a valid TTL
    if get_cached(callsign) do
      {:noreply, state}
    else
      {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    timer = schedule_tick()
    new_state = process_next(%{state | timer: timer})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_cache(state.db)
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ────────────────────────────────────────────────────── queue processing ──

  defp process_next(%{queue: queue} = state) do
    case Enum.at(queue, 0) do
      nil ->
        state

      callsign ->
        remaining = MapSet.delete(queue, callsign)
        state = %{state | queue: remaining}

        if get_cached(callsign) do
          process_next(state)
        else
          do_fetch(callsign, state)
        end
    end
  end

  defp do_fetch(callsign, state) do
    case api_key() do
      nil ->
        Logger.warning("[AeroAPI] No API key configured, skipping enrichment for #{callsign}")
        state

      key ->
        base_url = aeroapi_config(:base_url)
        url = "#{base_url}/flights/#{URI.encode(callsign)}"
        headers = [{"x-apikey", key}]

        case Req.get(url, headers: headers) do
          {:ok, %{status: 200, body: body}} ->
            case parse_flight(body) do
              {:ok, flight_info} ->
                new_state = cache_put(callsign, flight_info, state)

                Phoenix.PubSub.broadcast(
                  @pubsub,
                  @topic,
                  {:flight_enriched, callsign, flight_info}
                )

                Logger.debug("[AeroAPI] Enriched #{callsign}")

                # Increment monthly counter
                new_count = new_state.call_count + 1
                CubDB.put(new_state.db, {:calls, new_state.month_key}, new_count)
                Phoenix.PubSub.broadcast(@pubsub, "config", {:aeroapi_usage, new_count})

                # Reset counter if month rolled over
                current_month = month_key()

                if current_month != new_state.month_key do
                  CubDB.put(new_state.db, {:calls, current_month}, 1)
                  %{new_state | call_count: 1, month_key: current_month}
                else
                  %{new_state | call_count: new_count}
                end

              :error ->
                Logger.debug("[AeroAPI] No usable flight data for #{callsign}")
                state
            end

          {:ok, %{status: 404}} ->
            Logger.debug("[AeroAPI] Flight not found: #{callsign}")
            state

          {:ok, %{status: 429}} ->
            Logger.warning("[AeroAPI] Rate limited (429) for #{callsign}")
            state

          {:ok, %{status: status}} ->
            Logger.warning("[AeroAPI] Unexpected status #{status} for #{callsign}")
            state

          {:error, reason} ->
            Logger.warning("[AeroAPI] HTTP error for #{callsign}: #{inspect(reason)}")
            state
        end
    end
  end

  # ───────────────────────────────────────────────────────── parse helpers ──

  defp parse_flight(%{"flights" => [flight | _]}) do
    info = %FlightInfo{
      ident: Map.get(flight, "ident"),
      operator: Map.get(flight, "operator"),
      airline_name: Map.get(flight, "operator_iata") || Map.get(flight, "operator"),
      aircraft_type: get_in(flight, ["aircraft_type"]),
      origin: parse_airport(Map.get(flight, "origin")),
      destination: parse_airport(Map.get(flight, "destination")),
      departure_time: parse_time(Map.get(flight, "scheduled_out")),
      actual_departure_time: parse_time(Map.get(flight, "actual_out")),
      arrival_time: parse_time(Map.get(flight, "scheduled_in")),
      cached_at: DateTime.utc_now()
    }

    {:ok, info}
  end

  defp parse_flight(_), do: :error

  defp parse_airport(nil), do: nil

  defp parse_airport(airport) when is_map(airport) do
    %Airport{
      icao: Map.get(airport, "code_icao"),
      iata: Map.get(airport, "code_iata"),
      name: Map.get(airport, "name"),
      city: Map.get(airport, "city")
    }
  end

  defp parse_time(nil), do: nil

  defp parse_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # ───────────────────────────────────────────────────────────── ETS cache ──

  defp cache_put(callsign, flight_info, state) do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {callsign, flight_info, now})
    CubDB.put(state.db, callsign, {flight_info, now})
    state
  end

  # ──────────────────────────────────────────────────────────── scheduling ──

  defp schedule_tick do
    Process.send_after(self(), :tick, @rate_limit_ms)
  end

  # Run once every 24 hours
  @prune_interval_ms 24 * 60 * 60 * 1_000

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_cache(db) do
    now = System.system_time(:second)

    # Delete callsign entries whose 24h TTL has expired
    expired_keys =
      CubDB.select(db)
      |> Stream.filter(fn
        {key, {_info, cached_at}} when is_binary(key) -> now - cached_at >= @cache_ttl_sec
        _ -> false
      end)
      |> Enum.map(fn {key, _} -> key end)

    # Delete call-counter entries older than 2 months
    current = Date.utc_today()
    cutoff = Date.add(current, -60)

    old_month_keys =
      CubDB.select(db)
      |> Stream.filter(fn
        {{:calls, month_str}, _} ->
          case Date.from_iso8601("#{month_str}-01") do
            {:ok, d} -> Date.before?(d, cutoff)
            _ -> false
          end

        _ ->
          false
      end)
      |> Enum.map(fn {key, _} -> key end)

    all_keys = expired_keys ++ old_month_keys

    if all_keys != [] do
      CubDB.delete_multi(db, all_keys)
      CubDB.compact(db)

      Logger.debug(
        "[AeroAPI] Pruned #{length(expired_keys)} expired entries, #{length(old_month_keys)} old month counters"
      )
    end
  end

  # ─────────────────────────────────────────────────────── month helpers ──

  defp month_key do
    date = Date.utc_today()
    "#{date.year}-#{String.pad_leading(to_string(date.month), 2, "0")}"
  end

  # ────────────────────────────────────────────────────────────── config ──

  defp api_key do
    key = Store.get(:aeroapi_key)
    if is_binary(key) and key != "", do: key, else: nil
  end

  defp aeroapi_config(key) do
    Application.get_env(:aerovision, :aeroapi)[key]
  end
end
