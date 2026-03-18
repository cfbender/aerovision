defmodule AeroVision.Flight.FlightStatus do
  @moduledoc """
  Flight enrichment orchestrator with FlightAware as primary source, FlightStats
  as secondary, and Skylink API as final fallback.

  For each callsign, enrichment is attempted in order:

  1. **FlightAware** (`AeroVision.Flight.Providers.FlightAware`) — preferred because it
     provides ICAO aircraft type codes instead of IATA.
  2. **FlightStats** (`AeroVision.Flight.Providers.FlightStats`) — scrapes flightstats.com
     when FlightAware fails; no API key required and no monthly counter increment.
  3. **Skylink API** (`AeroVision.Flight.Providers.Skylink.Api`) — called only when both
     free sources fail, credentials are configured, and the monthly cap has not
     been reached.

  Fetched data (origin/destination airports, airline name, departure/arrival
  times, flight status) is cached in ETS for 24 hours and persisted to CubDB
  so it survives reboots.

  Incoming enrichment requests are queued and processed at a max rate of
  1 request per second to respect API rate limits.

  Broadcasts `{:flight_enriched, callsign, %FlightInfo{}}` on PubSub topic
  "flights" when enrichment completes.

  Monthly Skylink API call counts are tracked by the Skylink provider to help
  stay within the free tier (~1,000 calls/month).
  """

  use GenServer

  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Providers.FlightAware
  alias AeroVision.Flight.Providers.FlightStats
  alias AeroVision.Flight.Providers.Skylink.Api, as: Skylink
  alias AeroVision.TimeSync

  require Logger

  @pubsub AeroVision.PubSub
  @topic "flights"

  @cache_table :aerovision_skylink_cache
  @cache_ttl_sec 86_400
  @refresh_ttl_sec 1_800
  @rate_limit_ms 1_000
  @persist_table :aerovision_skylink_persist
  # Buffer after scheduled arrival before considering cache stale (30 minutes)
  @arrival_buffer_sec 1_800

  # Bump this when cached data must be invalidated on next boot
  # (e.g. after fixing time-zone conversion bugs that produced bad timestamps).
  @cache_version 2

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

  @doc "Returns the number of Skylink API calls made this calendar month."
  def monthly_usage do
    Skylink.monthly_usage()
  end

  @doc "Clears all cached flight enrichment data from ETS and CubDB."
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  @doc "Synchronously look up a cached %FlightInfo{} by callsign, or nil."
  def get_cached(callsign) when is_binary(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, %FlightInfo{} = flight_info, cached_at}]
      when now - cached_at < @cache_ttl_sec ->
        if flight_arrived?(flight_info, now), do: nil, else: flight_info

      _ ->
        nil
    end
  end

  @doc """
  Returns true if a callsign's cached enrichment data exists but is older
  than the refresh TTL. Used by the Tracker to decide when tracked flights
  need re-enrichment for updated ETAs and status.
  """
  def needs_refresh?(callsign) when is_binary(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, %FlightInfo{}, cached_at}]
      when now - cached_at >= @refresh_ttl_sec and now - cached_at < @cache_ttl_sec ->
        true

      _ ->
        false
    end
  end

  @doc """
  Force re-enrichment of a callsign by clearing its ETS cache entry and
  re-queuing it. Used to refresh tracked flights with updated ETAs and status.

  Unlike `enrich/1`, this bypasses the cache check so already-cached callsigns
  can be re-fetched. The CubDB entry is preserved as crash-recovery fallback.
  """
  def re_enrich(callsign) when is_binary(callsign) do
    GenServer.cast(__MODULE__, {:re_enrich, callsign})
    :ok
  end

  # Check if a callsign has been negatively cached (enrichment permanently failed).
  # Uses the same ETS table but stores :not_found as the value instead of %FlightInfo{}.
  defp negatively_cached?(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, :not_found, cached_at}] when now - cached_at < @cache_ttl_sec -> true
      _ -> false
    end
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(opts) do
    # Create the ETS cache table if it does not already exist; clear it if it
    # does (e.g. after a supervised restart, so stale entries don't linger).
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    else
      :ets.delete_all_objects(@cache_table)
    end

    data_dir =
      Keyword.get(opts, :data_dir) ||
        case Application.get_env(:aerovision, :target, :host) do
          target when target in [:host, :test] ->
            Path.join(System.user_home!(), ".aerovision/skylink_cache")

          _ ->
            "/data/aerovision/skylink_cache"
        end

    File.mkdir_p!(data_dir)

    # Use a named CubDB only when no custom data_dir was provided (i.e. normal
    # startup). In tests, each test passes its own data_dir and we must NOT
    # share the named table or subsequent start_supervised! calls would get the
    # old process back via :already_started.
    db_opts =
      if Keyword.has_key?(opts, :data_dir) do
        [data_dir: data_dir]
      else
        [data_dir: data_dir, name: @persist_table]
      end

    db = AeroVision.DB.open(db_opts)

    # Load valid cache entries into ETS and purge expired ones from CubDB
    now = System.system_time(:second)

    db
    |> CubDB.select()
    |> Enum.each(fn
      {key, {:not_found, cached_at}} when is_binary(key) ->
        if now - cached_at < @cache_ttl_sec do
          :ets.insert(@cache_table, {key, :not_found, cached_at})
        else
          CubDB.delete(db, key)
        end

      {key, {flight_info, cached_at}} when is_binary(key) ->
        if now - cached_at < @cache_ttl_sec do
          :ets.insert(@cache_table, {key, flight_info, cached_at})
        else
          CubDB.delete(db, key)
        end

      _ ->
        :ok
    end)

    # Check cache version — if stale, wipe enrichment data so incorrectly-stored
    # entries (e.g. local times stored as UTC before zoneinfo fix) don't linger.
    stored_version = CubDB.get(db, :cache_version, 0)

    if stored_version < @cache_version do
      Logger.info("[FlightStatus] Cache version #{stored_version} < #{@cache_version} — clearing stale enrichment data")

      :ets.delete_all_objects(@cache_table)

      # Clear only string (callsign) keys; preserve system keys like :cache_version
      string_keys =
        db
        |> CubDB.select()
        |> Enum.filter(fn {key, _} -> is_binary(key) end)
        |> Enum.map(fn {key, _} -> key end)

      if string_keys != [], do: CubDB.delete_multi(db, string_keys)
      CubDB.put(db, :cache_version, @cache_version)
    end

    state = %{
      queue: MapSet.new(),
      timer: nil,
      db: db
    }

    timer = schedule_tick()
    schedule_prune()
    {:ok, %{state | timer: timer}}
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    # Clear ETS cache
    :ets.delete_all_objects(@cache_table)

    # Clear callsign-keyed entries from CubDB (preserve monthly call counters)
    # Collect all string keys, then delete in one batch operation for better performance
    keys_to_delete =
      state.db
      |> CubDB.select()
      |> Enum.filter(fn
        {key, _} when is_binary(key) -> true
        _ -> false
      end)
      |> Enum.map(fn {key, _} -> key end)

    if keys_to_delete != [] do
      CubDB.delete_multi(state.db, keys_to_delete)
    end

    Logger.info("[FlightStatus] Cache purged")
    {:reply, :ok, %{state | queue: MapSet.new()}}
  end

  @impl true
  def handle_cast({:enrich, callsign}, state) do
    # Skip if already cached (positively or negatively) with a valid TTL
    if get_cached(callsign) || negatively_cached?(callsign) do
      {:noreply, state}
    else
      {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
    end
  end

  @impl true
  def handle_cast({:re_enrich, callsign}, state) do
    # Delete the ETS entry so the regular enrich gate passes through.
    # CubDB entry is preserved as crash-recovery fallback.
    :ets.delete(@cache_table, callsign)
    # Now enqueue via the normal path — get_cached will return nil
    {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
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

        if get_cached(callsign) || negatively_cached?(callsign) do
          process_next(state)
        else
          do_fetch(callsign, state)
        end
    end
  end

  defp do_fetch(callsign, state) do
    if TimeSync.synchronized?() do
      try_providers(callsign, state)
    else
      Logger.debug("[FlightStatus] Clock not synced — deferring #{callsign}")
      %{state | queue: MapSet.put(state.queue, callsign)}
    end
  end

  # ──────────────────────────────────────────────── provider waterfall ──

  @providers [FlightAware, FlightStats, Skylink]

  defp try_providers(callsign, state) do
    result =
      Enum.reduce_while(@providers, [], fn provider, errors ->
        case provider.fetch(callsign) do
          {:ok, flight_info} ->
            {:halt, {:ok, flight_info, provider}}

          {:error, reason} ->
            Logger.debug("[FlightStatus] #{provider.name()} failed for #{callsign}: #{inspect(reason)}")
            {:cont, [{provider, reason} | errors]}
        end
      end)

    case result do
      {:ok, flight_info, provider} ->
        handle_success(callsign, flight_info, provider.name(), state)

      errors when is_list(errors) ->
        if Enum.all?(errors, fn {_provider, reason} -> permanent_failure?(reason) end) do
          Logger.debug("[FlightStatus] All providers permanently failed for #{callsign}, negative-caching")
          negative_cache_put(callsign, state)
        else
          state
        end
    end
  end

  defp handle_success(callsign, flight_info, provider_name, state) do
    Logger.debug("[FlightStatus] Enriched #{callsign} via #{provider_name}")
    new_state = cache_put(callsign, flight_info, state)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flight_enriched, callsign, flight_info})
    new_state
  end

  # Errors that indicate the callsign will never enrich successfully — cache negatively.
  defp permanent_failure?(:unknown_callsign), do: true
  defp permanent_failure?(:no_flight_data), do: true
  defp permanent_failure?(:no_bootstrap_data), do: true
  defp permanent_failure?(:not_configured), do: true
  defp permanent_failure?(:monthly_cap_reached), do: true
  defp permanent_failure?({:http_status, 404}), do: true
  defp permanent_failure?(_), do: false

  # ───────────────────────────────────────────────────────── ETS cache ──

  defp cache_put(callsign, flight_info, state) do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {callsign, flight_info, now})
    CubDB.put(state.db, callsign, {flight_info, now})
    state
  end

  defp negative_cache_put(callsign, state) do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {callsign, :not_found, now})
    CubDB.put(state.db, callsign, {:not_found, now})
    state
  end

  # Returns true when the scheduled arrival time + buffer has already passed,
  # meaning the cache entry should be treated as stale. Since arrival_time is
  # now a correctly-converted UTC DateTime, a simple Unix comparison is enough.
  defp flight_arrived?(%FlightInfo{arrival_time: nil}, _now), do: false

  defp flight_arrived?(%FlightInfo{arrival_time: arr}, now) do
    DateTime.to_unix(arr) + @arrival_buffer_sec < now
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

    # Delete callsign entries whose 24h TTL has expired (both positive and negative cache entries)
    expired_keys =
      db
      |> CubDB.select()
      |> Stream.filter(fn
        {key, {:not_found, cached_at}} when is_binary(key) -> now - cached_at >= @cache_ttl_sec
        {key, {_info, cached_at}} when is_binary(key) -> now - cached_at >= @cache_ttl_sec
        _ -> false
      end)
      |> Enum.map(fn {key, _} -> key end)

    if expired_keys != [] do
      CubDB.delete_multi(db, expired_keys)
      CubDB.compact(db)
      Logger.debug("[FlightStatus] Pruned #{length(expired_keys)} expired cache entries")
    end
  end
end
