defmodule AeroVision.Flight.OpenSky do
  @moduledoc """
  OpenSky ADS-B poller.

  Polls the OpenSky Network REST API (`/states/all`) on a 30-second interval,
  authenticates via OAuth2 client credentials, converts the response into
  `%StateVector{}` structs, and broadcasts them on the "flights" PubSub topic.

  ## Activation logic

  OpenSky polls when **either** condition is true:

  - Mode is `:nearby` AND OpenSky credentials are configured — primary nearby
    source, fetches within a geographic bounding box.
  - Mode is `:tracked` AND Skylink API key is NOT configured — fallback tracked
    source, performs a global fetch then filters to tracked callsigns.

  The poller is idle (no scheduled fetches) when neither condition is met.

  ## OAuth2 tokens

  Tokens are cached in state and refreshed automatically when fewer than
  `@token_refresh_buffer_sec` seconds remain before expiry.
  """

  use GenServer

  alias AeroVision.Config.Store
  alias AeroVision.Flight.GeoUtils
  alias AeroVision.Flight.StateVector
  alias AeroVision.TimeSync

  require Logger

  @pubsub AeroVision.PubSub
  @topic "flights"
  @poll_interval_ms 30_000
  @token_refresh_buffer_sec 300

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
      token: nil,
      token_expires_at: 0
    }

    {:ok, state, {:continue, :start_polling}}
  end

  @impl true
  def handle_continue(:start_polling, state) do
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "config")

    if opensky_configured?() do
      Logger.info("[OpenSky] Starting poller")
    else
      Logger.warning("[OpenSky] No credentials configured — polling disabled")
    end

    # Fetch immediately on startup, then schedule the recurring timer
    new_state = do_fetch(state)
    {:noreply, schedule_poll(new_state)}
  end

  @impl true
  def handle_cast(:fetch_now, state) do
    {:noreply, do_fetch(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_fetch(state)
    {:noreply, schedule_poll(new_state)}
  end

  # When location changes, debounce rapid changes and trigger a re-poll in 500ms.
  # If lat, lon, and radius all change in quick succession (three separate
  # config_changed messages), only one HTTP request fires.
  @impl true
  def handle_info({:config_changed, key, _value}, state) when key in [:location_lat, :location_lon, :radius_km] do
    if state.mode == :nearby do
      Logger.info("[OpenSky] Location changed, scheduling re-poll")
      if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
      timer = Process.send_after(self(), :poll, 500)
      {:noreply, %{state | poll_timer: timer}}
    else
      {:noreply, state}
    end
  end

  # When display mode changes, update state and reschedule.
  def handle_info({:config_changed, :display_mode, value}, state) do
    Logger.info("[OpenSky] Display mode changed to #{value}, rescheduling")
    new_state = %{state | mode: value}
    {:noreply, schedule_poll(new_state)}
  end

  # When tracked flights list changes, reschedule (relevant in tracked fallback mode).
  def handle_info({:config_changed, :tracked_flights, _value}, state) do
    Logger.info("[OpenSky] Tracked flights changed, rescheduling")
    {:noreply, schedule_poll(state)}
  end

  # When OpenSky credentials change, reschedule (may enable or disable polling).
  def handle_info({:config_changed, key, _value}, state) when key in [:opensky_client_id, :opensky_client_secret] do
    Logger.info("[OpenSky] Credentials changed, rescheduling")
    {:noreply, schedule_poll(state)}
  end

  # When Skylink API key changes, reschedule (affects whether we are fallback).
  def handle_info({:config_changed, :skylink_api_key, _value}, state) do
    Logger.info("[OpenSky] Skylink key changed, rescheduling")
    {:noreply, schedule_poll(state)}
  end

  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ─────────────────────────────────────────────────────────── fetch logic ──

  defp do_fetch(state) do
    if TimeSync.synchronized?() do
      if should_poll?(state) do
        case ensure_token(state) do
          {:ok, new_state} ->
            vectors = fetch_states(new_state)
            Phoenix.PubSub.broadcast(@pubsub, @topic, {:flights_raw, vectors})
            new_state

          {:error, state} ->
            state
        end
      else
        state
      end
    else
      Logger.debug("[OpenSky] Clock not synced — deferring poll")
      schedule_poll(state)
      state
    end
  end

  defp fetch_states(state) do
    url = opensky_config(:base_url) <> "/states/all"

    params =
      case state.mode do
        :nearby ->
          lat = Store.get(:location_lat)
          lon = Store.get(:location_lon)
          radius_km = Store.get(:radius_km)
          {min_lat, min_lon, max_lat, max_lon} = GeoUtils.bounding_box(lat, lon, radius_km)
          %{lamin: min_lat, lomin: min_lon, lamax: max_lat, lomax: max_lon}

        _ ->
          # Fallback tracked mode — global fetch (no bbox)
          %{}
      end

    headers = [{"Authorization", "Bearer #{state.token}"}]

    case Req.get(url, headers: headers, params: params) do
      {:ok, %{status: 200, body: body}} ->
        states = body["states"] || []

        vectors =
          states
          |> Enum.map(&StateVector.from_opensky/1)
          |> Enum.reject(&is_nil/1)
          |> filter_by_callsign(state.mode)

        Logger.debug("[OpenSky] Fetched #{length(vectors)} state vectors")
        vectors

      {:ok, %{status: 429}} ->
        Logger.warning("[OpenSky] Rate limited (429)")
        []

      {:ok, %{status: status}} ->
        Logger.warning("[OpenSky] Unexpected status #{status}")
        []

      {:error, reason} ->
        Logger.warning("[OpenSky] HTTP error: #{inspect(reason)}")
        []
    end
  end

  # In tracked fallback mode, filter down to just the tracked callsigns.
  defp filter_by_callsign(vectors, :nearby), do: vectors

  defp filter_by_callsign(vectors, _tracked) do
    tracked = Store.get(:tracked_flights)

    if tracked == [] do
      []
    else
      Enum.filter(vectors, fn sv ->
        sv.callsign &&
          Enum.any?(tracked, fn t ->
            String.downcase(sv.callsign) == String.downcase(t)
          end)
      end)
    end
  end

  # ──────────────────────────────────────────────────────── OAuth2 token ──

  defp fetch_token do
    id = Store.get(:opensky_client_id)
    secret = Store.get(:opensky_client_secret)
    token_url = opensky_config(:token_url)

    body = %{
      grant_type: "client_credentials",
      client_id: id,
      client_secret: secret
    }

    case Req.post(token_url, form: body) do
      {:ok, %{status: 200, body: body}} ->
        token = body["access_token"]
        expires_in = body["expires_in"] || 1800
        expires_at = System.system_time(:second) + expires_in
        Logger.debug("[OpenSky] Token refreshed")
        {:ok, token, expires_at}

      _ ->
        Logger.warning("[OpenSky] Token fetch failed")
        {:error, :token_fetch_failed}
    end
  end

  defp valid_token?(state) do
    state.token != nil and
      System.system_time(:second) < state.token_expires_at - @token_refresh_buffer_sec
  end

  defp ensure_token(state) do
    if valid_token?(state) do
      {:ok, state}
    else
      case fetch_token() do
        {:ok, token, expires_at} ->
          {:ok, %{state | token: token, token_expires_at: expires_at}}

        {:error, _} ->
          {:error, state}
      end
    end
  end

  # ─────────────────────────────────────────────────────────── scheduling ──

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    if should_poll?(state) do
      timer = Process.send_after(self(), :poll, @poll_interval_ms)
      %{state | poll_timer: timer}
    else
      %{state | poll_timer: nil}
    end
  end

  # ──────────────────────────────────────────────────────────── helpers ──

  defp should_poll?(%{mode: :nearby} = _state) do
    opensky_configured?()
  end

  defp should_poll?(_state) do
    # Fallback: poll in tracked mode only if Skylink has no key
    opensky_configured?() and not skylink_configured?()
  end

  defp opensky_configured? do
    id = Store.get(:opensky_client_id)
    secret = Store.get(:opensky_client_secret)
    is_binary(id) and id != "" and is_binary(secret) and secret != ""
  end

  defp skylink_configured? do
    key = Store.get(:skylink_api_key)
    is_binary(key) and key != ""
  end

  defp opensky_config(key) do
    Application.get_env(:aerovision, :opensky)[key]
  end
end
