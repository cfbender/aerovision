defmodule AeroVision.Display.Renderer do
  @moduledoc """
  Builds display frames from live flight data and sends them to `Display.Driver`.

  ## Subscriptions
  - PubSub topic `"display"` → `{:display_flights, [%TrackedFlight{}]}`
  - PubSub topic `"config"`  → `{:config_changed, key, value}` (brightness / cycle interval)
  - PubSub topic `"network"` → `{:network, :connected, ip}` (QR code data refresh)
  - PubSub topic `"gpio"`    → `{:button, :short_press}` → show QR code for 10 s

  ## Modes
  - `:loading`  — no flights available; shows "SCANNING..." text
  - `:flights`  — cycles through the tracked-flight list on a timer
  - `:qr`       — shows a QR code for the device IP; pauses flight cycling for 10 s
  """

  use GenServer
  require Logger

  alias AeroVision.Display.Driver
  alias AeroVision.Flight.GeoUtils
  alias AeroVision.Network.Manager, as: NetworkManager

  @pubsub AeroVision.PubSub
  @default_cycle_seconds 8
  @qr_duration_ms 10_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, "display")
    Phoenix.PubSub.subscribe(@pubsub, "config")
    Phoenix.PubSub.subscribe(@pubsub, "network")
    Phoenix.PubSub.subscribe(@pubsub, "gpio")

    cycle_seconds = AeroVision.Config.Store.get(:display_cycle_seconds) || @default_cycle_seconds

    state = %{
      flights: [],
      current_index: 0,
      cycle_timer: nil,
      qr_timer: nil,
      mode: :loading,
      cycle_seconds: cycle_seconds
    }

    render(state)
    {:ok, state}
  end

  # --- PubSub: new flight list ------------------------------------------------

  @impl true
  def handle_info({:display_flights, flights}, state) do
    state = %{state | flights: flights}

    state =
      cond do
        # Stay in QR mode if a QR timer is active
        state.mode == :qr ->
          state

        flights == [] ->
          cancel_cycle_timer(state) |> Map.put(:mode, :loading) |> Map.put(:current_index, 0)

        true ->
          state
          |> Map.put(:mode, :flights)
          |> ensure_cycle_timer()
      end

    render(state)
    {:noreply, state}
  end

  # --- PubSub: config changes -------------------------------------------------

  @impl true
  def handle_info({:config_changed, :display_cycle_seconds, seconds}, state) do
    Logger.info("[Display.Renderer] Cycle interval updated to #{seconds}s")
    state = %{state | cycle_seconds: seconds}
    # Restart the cycle timer so the new interval takes effect immediately
    state = state |> cancel_cycle_timer() |> ensure_cycle_timer()
    {:noreply, state}
  end

  def handle_info({:config_changed, :display_brightness, brightness}, state) do
    Logger.info("[Display.Renderer] Brightness updated to #{brightness}")
    Driver.send_command(%{cmd: "set_brightness", value: brightness})
    {:noreply, state}
  end

  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  # --- PubSub: network IP update ----------------------------------------------

  @impl true
  def handle_info({:network, :connected, _ip}, state) do
    # Nothing to do proactively; we'll call current_ip/0 when QR is requested
    {:noreply, state}
  end

  def handle_info({:network, _event}, state) do
    {:noreply, state}
  end

  # --- PubSub: GPIO short press → show QR -------------------------------------

  @impl true
  def handle_info({:button, :short_press}, state) do
    Logger.info("[Display.Renderer] Short press — showing QR code")
    state = show_qr(state)
    {:noreply, state}
  end

  def handle_info({:button, _press}, state) do
    {:noreply, state}
  end

  # --- Cycle timer fired ------------------------------------------------------

  @impl true
  def handle_info(:cycle_tick, %{mode: :qr} = state) do
    # Don't advance while in QR mode — the timer will fire again after QR ends
    {:noreply, state}
  end

  def handle_info(:cycle_tick, %{flights: []} = state) do
    {:noreply, %{state | cycle_timer: nil, mode: :loading}}
  end

  def handle_info(:cycle_tick, state) do
    next_index = rem(state.current_index + 1, length(state.flights))
    state = %{state | current_index: next_index, cycle_timer: nil}
    state = ensure_cycle_timer(state)
    render(state)
    {:noreply, state}
  end

  # --- QR mode ends -----------------------------------------------------------

  @impl true
  def handle_info(:qr_end, state) do
    Logger.info("[Display.Renderer] QR mode ended — resuming flights")

    state =
      %{state | mode: if(state.flights == [], do: :loading, else: :flights), qr_timer: nil}

    state = ensure_cycle_timer(state)
    render(state)
    {:noreply, state}
  end

  # --- Catch-all --------------------------------------------------------------

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Display.Renderer] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp render(%{mode: :loading}) do
    Driver.send_command(%{cmd: "scan_anim"})
  end

  defp render(%{mode: :qr}) do
    ip = NetworkManager.current_ip() || "aerovision.local"
    url = "http://#{ip}"
    Logger.debug("[Display.Renderer] Showing QR for #{url}")
    Driver.send_command(%{cmd: "qr", data: url})
  end

  defp render(%{mode: :flights, flights: [], current_index: _}) do
    # Shouldn't happen, but guard anyway
    render(%{mode: :loading})
  end

  defp render(%{mode: :flights, flights: flights, current_index: index}) do
    flight = Enum.at(flights, index)
    command = build_flight_card(flight)
    Driver.send_command(command)
  end

  defp render(_state), do: :ok

  # ---------------------------------------------------------------------------
  # Flight card builder
  # ---------------------------------------------------------------------------

  defp build_flight_card(flight) do
    sv = flight.state_vector
    fi = flight.flight_info

    %{
      cmd: "flight_card",
      airline: airline_name(fi),
      flight: flight_ident(fi, sv),
      aircraft: aircraft_type(fi),
      route_origin: airport_code(fi && fi.origin),
      route_dest: airport_code(fi && fi.destination),
      altitude_ft: sv.baro_altitude |> GeoUtils.meters_to_feet() |> safe_round(),
      speed_kt: sv.velocity |> GeoUtils.ms_to_knots() |> safe_round(),
      bearing_deg: sv.true_track |> safe_round(),
      vrate_fpm: sv.vertical_rate |> meters_per_sec_to_fpm(),
      dep_time: format_time(fi && fi.departure_time),
      arr_time: format_time(fi && fi.arrival_time),
      progress: (fi && fi.progress_pct) || 0.0,
      airline_color: [0, 200, 220]
    }
  end

  defp airline_name(nil), do: nil
  defp airline_name(fi), do: fi.airline_name |> truncate(7) |> upcase_safe()

  defp flight_ident(nil, sv), do: sv.callsign
  defp flight_ident(fi, sv), do: fi.ident || sv.callsign

  defp aircraft_type(nil), do: "---"
  defp aircraft_type(fi), do: fi.aircraft_type || "---"

  defp airport_code(nil), do: nil
  defp airport_code(airport), do: airport.iata || airport.icao

  defp upcase_safe(nil), do: nil
  defp upcase_safe(str), do: String.upcase(str)

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  @doc "Format a DateTime as HH:MM. Returns \"--:--\" if nil."
  def format_time(nil), do: "--:--"

  def format_time(%DateTime{} = dt) do
    dt
    |> Calendar.strftime("%H:%M")
  end

  @doc "Convert m/s vertical rate to feet per minute."
  def meters_per_sec_to_fpm(nil), do: nil
  def meters_per_sec_to_fpm(ms), do: round(ms * 196.85)

  @doc "Round a number, returning nil if the input is nil."
  def safe_round(nil), do: nil
  def safe_round(n), do: round(n)

  @doc "Slice a string to at most `max` characters, returning nil if nil."
  def truncate(nil, _max), do: nil
  def truncate(str, max), do: String.slice(str, 0, max)

  # ---------------------------------------------------------------------------
  # Timer helpers
  # ---------------------------------------------------------------------------

  defp ensure_cycle_timer(%{mode: :loading} = state), do: state
  defp ensure_cycle_timer(%{mode: :qr} = state), do: state
  defp ensure_cycle_timer(%{cycle_timer: ref} = state) when not is_nil(ref), do: state

  defp ensure_cycle_timer(state) do
    ms = (state.cycle_seconds || @default_cycle_seconds) * 1_000
    ref = Process.send_after(self(), :cycle_tick, ms)
    %{state | cycle_timer: ref}
  end

  defp cancel_cycle_timer(%{cycle_timer: nil} = state), do: state

  defp cancel_cycle_timer(%{cycle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | cycle_timer: nil}
  end

  defp show_qr(state) do
    # Cancel any existing QR timer
    state =
      case state.qr_timer do
        nil ->
          state

        ref ->
          Process.cancel_timer(ref)
          %{state | qr_timer: nil}
      end

    qr_ref = Process.send_after(self(), :qr_end, @qr_duration_ms)
    state = %{state | mode: :qr, qr_timer: qr_ref}
    render(state)
    state
  end
end
