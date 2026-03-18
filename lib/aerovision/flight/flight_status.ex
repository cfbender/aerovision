defmodule AeroVision.Flight.FlightStatus do
  @moduledoc """
  Flight enrichment orchestrator with FlightAware as primary source, FlightStats
  as secondary, and Skylink API as final fallback.

  For each callsign, enrichment is attempted in order:

  1. **FlightAware** (`AeroVision.Flight.FlightAware`) — preferred because it
     provides ICAO aircraft type codes instead of IATA.
  2. **FlightStats** (`AeroVision.Flight.FlightStats`) — scrapes flightstats.com
     when FlightAware fails; no API key required and no monthly counter increment.
  3. **Skylink API** (`AeroVision.Flight.Skylink.Api`) — called only when both
     free sources fail, credentials are configured, and the monthly cap has not
     been reached.

  Fetched data (origin/destination airports, airline name, departure/arrival
  times, flight status) is cached for 24 hours via `AeroVision.Cache` and
  persisted to disk so it survives reboots.

  Incoming enrichment requests are queued and processed at a max rate of
  1 request per second to respect API rate limits.

  Broadcasts `{:flight_enriched, callsign, %FlightInfo{}}` on PubSub topic
  "flights" when enrichment completes.

  Monthly Skylink API call counts are tracked by the Skylink provider to help
  stay within the free tier (~1,000 calls/month).
  """

  use GenServer

  alias AeroVision.Cache
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Providers.FlightAware
  alias AeroVision.Flight.Providers.FlightStats
  alias AeroVision.Flight.Providers.Skylink.Api, as: SkylinkApi
  alias AeroVision.TimeSync

  require Logger

  @pubsub AeroVision.PubSub
  @topic "flights"

  @cache :flight_cache
  @cache_ttl_sec 86_400
  @refresh_ttl_sec 1_800
  @rate_limit_ms 1_000
  # Buffer after scheduled arrival before considering cache stale (30 minutes)
  @arrival_buffer_sec 1_800

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
    SkylinkApi.monthly_usage()
  end

  @doc "Clears all cached flight enrichment data."
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  @doc "Synchronously look up a cached %FlightInfo{} by callsign, or nil."
  def get_cached(callsign) when is_binary(callsign) do
    now = System.system_time(:second)

    case Cache.get(@cache, callsign) do
      {%FlightInfo{} = flight_info, cached_at}
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

    case Cache.get(@cache, callsign) do
      {%FlightInfo{}, cached_at}
      when now - cached_at >= @refresh_ttl_sec and now - cached_at < @cache_ttl_sec ->
        true

      _ ->
        false
    end
  end

  @doc """
  Force re-enrichment of a callsign by evicting its cache entry and
  re-queuing it. Used to refresh tracked flights with updated ETAs and status.

  Unlike `enrich/1`, this bypasses the cache check so already-cached callsigns
  can be re-fetched. The persistent entry is preserved as crash-recovery fallback.
  """
  def re_enrich(callsign) when is_binary(callsign) do
    GenServer.cast(__MODULE__, {:re_enrich, callsign})
    :ok
  end

  # Check if a callsign has been negatively cached (enrichment permanently failed).
  defp negatively_cached?(callsign) do
    now = System.system_time(:second)

    case Cache.get(@cache, callsign) do
      {:not_found, cached_at} when now - cached_at < @cache_ttl_sec -> true
      _ -> false
    end
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(_opts) do
    timer = schedule_tick()

    {:ok, %{queue: MapSet.new(), timer: timer}}
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    Cache.clear(@cache)
    Logger.info("[FlightStatus] Cache purged")
    {:reply, :ok, %{state | queue: MapSet.new()}}
  end

  @impl true
  def handle_cast({:enrich, callsign}, state) do
    if get_cached(callsign) || negatively_cached?(callsign) do
      {:noreply, state}
    else
      {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
    end
  end

  @impl true
  def handle_cast({:re_enrich, callsign}, state) do
    Cache.evict(@cache, callsign)
    {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
  end

  @impl true
  def handle_info(:tick, state) do
    timer = schedule_tick()
    new_state = process_next(%{state | timer: timer})
    {:noreply, new_state}
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

  @providers [FlightAware, FlightStats, SkylinkApi]

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
          Cache.put(@cache, callsign, :not_found)
          state
        else
          state
        end
    end
  end

  defp handle_success(callsign, flight_info, provider_name, state) do
    Logger.debug("[FlightStatus] Enriched #{callsign} via #{provider_name}")
    Cache.put(@cache, callsign, flight_info)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flight_enriched, callsign, flight_info})
    state
  end

  # Errors that indicate the callsign will never enrich successfully — cache negatively.
  defp permanent_failure?(:unknown_callsign), do: true
  defp permanent_failure?(:no_flight_data), do: true
  defp permanent_failure?(:no_bootstrap_data), do: true
  defp permanent_failure?(:not_configured), do: true
  defp permanent_failure?(:monthly_cap_reached), do: true
  defp permanent_failure?({:http_status, 404}), do: true
  defp permanent_failure?(_), do: false

  # ─────────────────────────────────────────────────────── flight helpers ──

  # Returns true when the scheduled arrival time + buffer has already passed.
  defp flight_arrived?(%FlightInfo{arrival_time: nil}, _now), do: false

  defp flight_arrived?(%FlightInfo{arrival_time: arr}, now) do
    DateTime.to_unix(arr) + @arrival_buffer_sec < now
  end

  # ──────────────────────────────────────────────────────────── scheduling ──

  defp schedule_tick do
    Process.send_after(self(), :tick, @rate_limit_ms)
  end
end
