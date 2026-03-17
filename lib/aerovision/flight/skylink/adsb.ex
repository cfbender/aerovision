defmodule AeroVision.Flight.Skylink.ADSB do
  @moduledoc """
  Skylink ADS-B poller.

  Polls the Skylink API (`/adsb/aircraft`) on a configurable interval,
  authenticates via a RapidAPI key header, converts the response into
  `%StateVector{}` structs, and broadcasts them on the "flights" PubSub topic.

  If no API key is configured the poller runs in a no-op mode and logs a
  warning once at startup — it will never crash.

  ## Modes

  - `:nearby` — fetches aircraft within a geographic radius using lat/lon/radius params.
    Only active when Skylink is configured AND OpenSky credentials are NOT configured
    (i.e. Skylink is the fallback nearby source). Polls every 30 seconds.
  - `:tracked` — fetches one request per tracked callsign and combines all results,
    deduped by icao24. Active whenever Skylink is configured, regardless of OpenSky.
    Polls every 5 minutes.

  When OpenSky credentials are present, Skylink goes idle for nearby mode and lets
  OpenSky handle it. When OpenSky credentials are added or removed at runtime,
  Skylink immediately re-evaluates whether it should be polling.
  """

  use GenServer
  require Logger

  alias AeroVision.Flight.StateVector
  alias AeroVision.Config.Store
  alias AeroVision.TimeSync

  @pubsub AeroVision.PubSub
  @topic "flights"

  # ─────────────────────────────────────────────────────────── public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate fetch cycle (useful in tests / dev)."
  def fetch_now do
    GenServer.cast(__MODULE__, :fetch_now)
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(_opts) do
    state = %{
      poll_timer: nil,
      mode: Store.get(:display_mode),
      last_fetch_at: nil
    }

    {:ok, state, {:continue, :start_polling}}
  end

  @impl true
  def handle_continue(:start_polling, state) do
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "config")

    if skylink_configured?() do
      Logger.info("[Skylink.ADSB] Starting poller")
    else
      Logger.warning("[Skylink.ADSB] No API key configured — polling disabled")
    end

    # Only fetch immediately on startup if we should be polling; otherwise
    # just call schedule_poll/1 which will set poll_timer: nil when idle.
    new_state =
      if should_poll?(state) do
        do_fetch(state)
      else
        state
      end

    {:noreply, schedule_poll(new_state)}
  end

  @impl true
  def handle_cast(:fetch_now, state) do
    {:noreply, do_fetch(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state =
      if should_poll?(state) do
        do_fetch(state)
      else
        state
      end

    {:noreply, schedule_poll(new_state)}
  end

  # When location changes, trigger an immediate re-poll with the new bounding area.
  # Debounce rapid location changes — cancel the existing timer and schedule a
  # fresh fetch in 500ms. If lat, lon, and radius all change in quick succession
  # (three separate config_changed messages), only one HTTP request fires.
  @impl true
  def handle_info({:config_changed, key, _value}, state)
      when key in [:location_lat, :location_lon, :radius_km] do
    Logger.info("[Skylink.ADSB] Location changed, scheduling re-poll")
    new_state = cancel_poll_timer(state)
    timer = Process.send_after(self(), :poll, 500)
    {:noreply, %{new_state | poll_timer: timer}}
  end

  # When display mode changes, update state and trigger an immediate re-poll.
  def handle_info({:config_changed, :display_mode, value}, state) do
    Logger.info("[Skylink.ADSB] Display mode changed to #{value}, scheduling re-poll")
    new_state = cancel_poll_timer(state)
    timer = Process.send_after(self(), :poll, 500)
    {:noreply, %{new_state | mode: value, poll_timer: timer}}
  end

  # When tracked flights list changes, trigger an immediate re-poll.
  def handle_info({:config_changed, :tracked_flights, _value}, state) do
    Logger.info("[Skylink.ADSB] Tracked flights changed, scheduling re-poll")
    new_state = cancel_poll_timer(state)
    timer = Process.send_after(self(), :poll, 500)
    {:noreply, %{new_state | poll_timer: timer}}
  end

  # When OpenSky credentials change, our fallback status for nearby mode may
  # have changed — re-evaluate immediately.
  def handle_info({:config_changed, key, _value}, state)
      when key in [:opensky_client_id, :opensky_client_secret] do
    Logger.debug("[Skylink.ADSB] OpenSky credentials changed, re-evaluating polling")
    new_state = cancel_poll_timer(state)
    timer = Process.send_after(self(), :poll, 500)
    {:noreply, %{new_state | poll_timer: timer}}
  end

  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ─────────────────────────────────────────────────────────── fetch logic ──

  defp do_fetch(state) do
    if not TimeSync.synchronized?() do
      Logger.debug("[Skylink.ADSB] Clock not synced — deferring poll")
      schedule_poll(state)
      state
    else
      if should_poll?(state) do
        fetch_aircraft(state)
      else
        state
      end
    end
  end

  defp fetch_aircraft(state) do
    vectors = fetch_by_mode(state.mode)
    Logger.debug("[Skylink.ADSB] Fetched #{length(vectors)} state vectors")
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flights_raw, vectors})
    %{state | last_fetch_at: DateTime.utc_now()}
  end

  defp fetch_by_mode(:nearby) do
    params = %{
      lat: Store.get(:location_lat),
      lon: Store.get(:location_lon),
      radius: Store.get(:radius_km)
    }

    case get_aircraft(params) do
      {:ok, vectors} -> vectors
      {:error, _} -> []
    end
  end

  defp fetch_by_mode(_tracked_mode) do
    callsigns = Store.get(:tracked_flights)

    if callsigns == [] do
      Logger.debug("[Skylink.ADSB] No tracked callsigns configured, skipping fetch")
      []
    else
      callsigns
      |> Enum.flat_map(fn callsign ->
        case get_aircraft(%{callsign: callsign}) do
          {:ok, vectors} -> vectors
          {:error, _} -> []
        end
      end)
      |> dedup_by_icao24()
    end
  end

  defp get_aircraft(params) do
    url = skylink_config(:base_url) <> "/adsb/aircraft"
    api_key = Store.get(:skylink_api_key)

    headers = [
      {"X-RapidAPI-Key", api_key},
      {"X-RapidAPI-Host", "skylink-api.p.rapidapi.com"},
      {"Content-Type", "application/json"}
    ]

    case Req.get(url, headers: headers, params: params) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_aircraft(body)}

      {:ok, %{status: 429}} ->
        Logger.warning("[Skylink.ADSB] 429 Too Many Requests — rate limited by RapidAPI")
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        Logger.warning("[Skylink.ADSB] Unexpected status #{status} from API")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("[Skylink.ADSB] HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────── parse helpers ──

  defp parse_aircraft(%{"aircraft" => aircraft}) when is_list(aircraft) do
    aircraft
    |> Enum.map(&StateVector.from_skylink/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_aircraft(_), do: []

  defp dedup_by_icao24(vectors) do
    vectors
    |> Enum.uniq_by(& &1.icao24)
  end

  # ─────────────────────────────────────────────────────────── scheduling ──

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    if should_poll?(state) do
      interval = poll_interval_ms(state.mode)
      timer = Process.send_after(self(), :poll, interval)
      %{state | poll_timer: timer}
    else
      %{state | poll_timer: nil}
    end
  end

  # 5 minutes for tracked mode, 30 seconds for nearby fallback
  defp poll_interval_ms(:tracked), do: 5 * 60 * 1_000
  defp poll_interval_ms(_nearby), do: 30_000

  defp cancel_poll_timer(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    %{state | poll_timer: nil}
  end

  # ──────────────────────────────────────────────────────────── helpers ──

  defp should_poll?(state) do
    case state.mode do
      :tracked -> skylink_configured?()
      :nearby -> skylink_configured?() and not opensky_configured?()
      _ -> false
    end
  end

  defp skylink_configured? do
    key = Store.get(:skylink_api_key)
    is_binary(key) and key != ""
  end

  defp opensky_configured? do
    id = Store.get(:opensky_client_id)
    secret = Store.get(:opensky_client_secret)
    is_binary(id) and id != "" and is_binary(secret) and secret != ""
  end

  defp skylink_config(key) do
    Application.get_env(:aerovision, :skylink)[key]
  end
end
