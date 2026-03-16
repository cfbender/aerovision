defmodule AeroVision.Flight.OpenSky do
  @moduledoc """
  OpenSky Network poller.

  Polls the OpenSky REST API on a configurable interval, authenticates via
  OAuth2 client-credentials, converts the response into `%StateVector{}`
  structs, and broadcasts them on the "flights" PubSub topic.

  If no credentials are configured the poller runs in a no-op mode and logs a
  warning once at startup — it will never crash.
  """

  use GenServer
  require Logger

  alias AeroVision.Flight.StateVector
  alias AeroVision.Config.Store

  @pubsub AeroVision.PubSub
  @topic "flights"

  # Tokens expire in 30 min; refresh when <= 5 min remain.
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
      token: nil,
      token_expires_at: nil,
      poll_timer: nil,
      rate_limit_remaining: nil,
      last_fetch_at: nil
    }

    {:ok, state, {:continue, :start_polling}}
  end

  @impl true
  def handle_continue(:start_polling, state) do
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "config")

    if credentials_configured?() do
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

  # When location changes, trigger an immediate re-poll with the new bounding box.
  # Debounce rapid location changes — cancel the existing timer and schedule a
  # fresh fetch in 500ms. If lat, lon, and radius all change in quick succession
  # (three separate config_changed messages), only one HTTP request fires.
  @impl true
  def handle_info({:config_changed, key, _value}, state)
      when key in [:location_lat, :location_lon, :radius_km] do
    Logger.info("[OpenSky] Location changed, scheduling re-poll")
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, 500)
    {:noreply, %{state | poll_timer: timer}}
  end

  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ─────────────────────────────────────────────────────────── fetch logic ──

  defp do_fetch(state) do
    cond do
      not credentials_configured?() ->
        state

      rate_limited?(state) ->
        Logger.warning("[OpenSky] Rate-limited, skipping this poll cycle")
        state

      true ->
        case ensure_token(state) do
          {:ok, token, new_state} ->
            fetch_states(token, new_state)

          {:error, reason, new_state} ->
            Logger.warning("[OpenSky] Token fetch failed: #{inspect(reason)}")
            new_state
        end
    end
  end

  defp fetch_states(token, state) do
    {min_lat, min_lon, max_lat, max_lon} = bounding_box()

    url =
      opensky_config(:base_url) <>
        "/states/all?" <>
        URI.encode_query(%{
          lamin: min_lat,
          lomin: min_lon,
          lamax: max_lat,
          lomax: max_lon
        })

    headers = [{"Authorization", "Bearer #{token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        remaining = parse_rate_limit(resp_headers)
        vectors = parse_states(body)
        Logger.debug("[OpenSky] Fetched #{length(vectors)} state vectors")
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:flights_raw, vectors})

        %{state | rate_limit_remaining: remaining, last_fetch_at: DateTime.utc_now()}

      {:ok, %{status: 429}} ->
        Logger.warning("[OpenSky] 429 Too Many Requests")
        %{state | rate_limit_remaining: 0}

      {:ok, %{status: status}} ->
        Logger.warning("[OpenSky] Unexpected status #{status} from API")
        state

      {:error, reason} ->
        Logger.warning("[OpenSky] HTTP error: #{inspect(reason)}")
        state
    end
  end

  # ──────────────────────────────────────────────────────── token handling ──

  defp ensure_token(%{token: token, token_expires_at: exp} = state)
       when is_binary(token) and is_integer(exp) do
    now = System.system_time(:second)

    if now + @token_refresh_buffer_sec < exp do
      {:ok, token, state}
    else
      fetch_token(state)
    end
  end

  defp ensure_token(state), do: fetch_token(state)

  defp fetch_token(state) do
    client_id = Store.get(:opensky_client_id)
    client_secret = Store.get(:opensky_client_secret)
    token_url = opensky_config(:token_url)

    body = %{
      grant_type: "client_credentials",
      client_id: client_id,
      client_secret: client_secret
    }

    case Req.post(token_url, form: body) do
      {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
        expires_at = System.system_time(:second) + expires_in
        Logger.debug("[OpenSky] Token refreshed, expires in #{expires_in}s")
        new_state = %{state | token: token, token_expires_at: expires_at}
        {:ok, token, new_state}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}", state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # ──────────────────────────────────────────────────────────── parse helpers ──

  defp parse_states(%{"states" => states}) when is_list(states) do
    states
    |> Enum.map(&StateVector.from_array/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_states(_), do: []

  defp parse_rate_limit(headers) do
    # Req returns headers as a map of %{name => [value, ...]}
    case Map.get(headers, "x-rate-limit-remaining") do
      [value | _] -> String.to_integer(value)
      nil -> nil
    end
  end

  # ─────────────────────────────────────────────────────────── scheduling ──

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    interval_ms = Store.get(:poll_interval_sec) * 1_000
    timer = Process.send_after(self(), :poll, interval_ms)
    %{state | poll_timer: timer}
  end

  # ──────────────────────────────────────────────────────────── helpers ──

  defp credentials_configured? do
    id = Store.get(:opensky_client_id)
    secret = Store.get(:opensky_client_secret)
    is_binary(id) and id != "" and is_binary(secret) and secret != ""
  end

  defp rate_limited?(%{rate_limit_remaining: 0}), do: true
  defp rate_limited?(_), do: false

  defp bounding_box do
    lat = Store.get(:location_lat)
    lon = Store.get(:location_lon)
    radius = Store.get(:radius_km)
    AeroVision.Flight.GeoUtils.bounding_box(lat, lon, radius)
  end

  defp opensky_config(key) do
    Application.get_env(:aerovision, :opensky)[key]
  end
end
