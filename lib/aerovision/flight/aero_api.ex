defmodule AeroVision.Flight.AeroAPI do
  @moduledoc """
  FlightAware AeroAPI v4 enrichment client.

  Fetches enriched flight data (origin/destination airports, aircraft type,
  airline name, departure/arrival times) for a given callsign and caches
  results in ETS for 1 hour.

  Incoming enrichment requests are queued and processed at a max rate of
  1 request per second to respect AeroAPI rate limits.

  Broadcasts `{:flight_enriched, callsign, %FlightInfo{}}` on PubSub topic
  "flights" when enrichment completes.
  """

  use GenServer
  require Logger

  alias AeroVision.Config.Store
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.Airport

  @pubsub AeroVision.PubSub
  @topic "flights"

  @cache_table :aerovision_aeroapi_cache
  @cache_ttl_sec 3600
  @rate_limit_ms 1_000

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

    state = %{
      queue: MapSet.new(),
      processing: false,
      timer: nil
    }

    timer = schedule_tick()
    {:ok, %{state | timer: timer}}
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

  # ────────────────────────────────────────────────────── queue processing ──

  defp process_next(%{queue: queue} = state) do
    case Enum.at(queue, 0) do
      nil ->
        state

      callsign ->
        remaining = MapSet.delete(queue, callsign)

        # Check cache again (may have been enriched while queued)
        if get_cached(callsign) do
          process_next(%{state | queue: remaining})
        else
          do_fetch(callsign)
          %{state | queue: remaining}
        end
    end
  end

  defp do_fetch(callsign) do
    case api_key() do
      nil ->
        Logger.warning("[AeroAPI] No API key configured, skipping enrichment for #{callsign}")

      key ->
        base_url = aeroapi_config(:base_url)
        url = "#{base_url}/flights/#{URI.encode(callsign)}"
        headers = [{"x-apikey", key}]

        case Req.get(url, headers: headers) do
          {:ok, %{status: 200, body: body}} ->
            case parse_flight(body) do
              {:ok, flight_info} ->
                cache_put(callsign, flight_info)

                Phoenix.PubSub.broadcast(
                  @pubsub,
                  @topic,
                  {:flight_enriched, callsign, flight_info}
                )

                Logger.debug("[AeroAPI] Enriched #{callsign}")

              :error ->
                Logger.debug("[AeroAPI] No usable flight data for #{callsign}")
            end

          {:ok, %{status: 404}} ->
            Logger.debug("[AeroAPI] Flight not found: #{callsign}")

          {:ok, %{status: 429}} ->
            Logger.warning("[AeroAPI] Rate limited (429) for #{callsign}")

          {:ok, %{status: status}} ->
            Logger.warning("[AeroAPI] Unexpected status #{status} for #{callsign}")

          {:error, reason} ->
            Logger.warning("[AeroAPI] HTTP error for #{callsign}: #{inspect(reason)}")
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

  defp cache_put(callsign, flight_info) do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {callsign, flight_info, now})
  end

  # ──────────────────────────────────────────────────────────── scheduling ──

  defp schedule_tick do
    Process.send_after(self(), :tick, @rate_limit_ms)
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
