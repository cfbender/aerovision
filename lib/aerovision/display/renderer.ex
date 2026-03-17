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

  alias AeroVision.Config.Store
  alias AeroVision.Display.Driver
  alias AeroVision.Flight.AircraftCodes
  alias AeroVision.Network.Manager, as: NetworkManager

  @pubsub AeroVision.PubSub
  @default_cycle_seconds 8
  @qr_duration_ms 10_000
  @ap_ssid "AeroVision-Setup"
  @ap_ip "192.168.24.1"

  # Modes that mean "not connected to WiFi yet" — QR is suppressed in these.
  @no_wifi_modes [:ap, :connecting, :loading, :disconnected]

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

    cycle_seconds = Store.get(:display_cycle_seconds) || @default_cycle_seconds

    # Start in AP mode immediately if we're not on WiFi yet — avoids briefly
    # showing the scan animation before the network :ap_mode broadcast arrives.
    # Guard against Network.Manager not being up yet (e.g. in tests).
    initial_mode =
      try do
        case NetworkManager.current_mode() do
          :ap -> :ap
          :connecting -> :connecting
          _ -> :loading
        end
      catch
        :exit, _ -> :loading
      end

    state = %{
      flights: [],
      current_index: 0,
      cycle_timer: nil,
      qr_timer: nil,
      mode: initial_mode,
      cycle_seconds: cycle_seconds,
      connecting_ssid: nil,
      last_command: nil
    }

    state = render(state)
    {:ok, state}
  end

  # --- PubSub: new flight list ------------------------------------------------

  @impl true
  def handle_info({:display_flights, flights}, state) do
    state = %{state | flights: flights}

    prev_mode = state.mode

    state =
      cond do
        # Network-state modes are never overridden by flight data
        state.mode in [:qr, :ap, :connecting, :disconnected] ->
          state

        flights == [] ->
          cancel_cycle_timer(state) |> Map.put(:mode, :loading) |> Map.put(:current_index, 0)

        true ->
          state
          |> Map.put(:mode, :flights)
          |> ensure_cycle_timer()
      end

    # Only re-render if the mode changed or new flights arrived in :flights mode.
    # Avoids restarting the scan animation on every poll when no flights are present.
    state =
      if state.mode != prev_mode or state.mode == :flights do
        Logger.debug("[Display.Renderer] Received #{length(flights)} flights — updating display")
        render(state)
      else
        state
      end

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
    Driver.send_command(%{cmd: "brightness", value: brightness})
    {:noreply, state}
  end

  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  # --- PubSub: network state changes ------------------------------------------

  @impl true
  def handle_info({:network, :ap_mode}, state) do
    Logger.info("[Display.Renderer] AP mode — showing setup screen")
    state = cancel_qr_timer(state)
    state = %{state | mode: :ap, connecting_ssid: nil}
    state = render(state)
    {:noreply, state}
  end

  def handle_info({:network, :connecting, ssid}, state) do
    Logger.info("[Display.Renderer] Connecting to #{ssid}")
    state = cancel_qr_timer(state)
    state = %{state | mode: :connecting, connecting_ssid: ssid}
    state = render(state)
    {:noreply, state}
  end

  def handle_info({:network, :disconnected}, state) do
    Logger.info("[Display.Renderer] WiFi disconnected — showing error screen")
    state = cancel_qr_timer(state)
    state = %{state | mode: :disconnected, connecting_ssid: nil}
    state = render(state)
    {:noreply, state}
  end

  def handle_info({:network, :connected, _ip}, state) do
    # Connected — clear connecting state, resume normal display
    state =
      if state.mode in [:ap, :connecting, :disconnected] do
        %{
          state
          | mode: if(state.flights == [], do: :loading, else: :flights),
            connecting_ssid: nil
        }
      else
        state
      end

    state = render(state)
    {:noreply, state}
  end

  def handle_info({:network, _event}, state) do
    {:noreply, state}
  end

  # --- PubSub: GPIO short press → show QR (only when WiFi connected) ----------

  @impl true
  def handle_info({:button, :short_press}, state) do
    if state.mode in @no_wifi_modes do
      Logger.debug("[Display.Renderer] Short press ignored — not connected to WiFi")
      {:noreply, state}
    else
      Logger.info("[Display.Renderer] Short press — showing QR code")
      {:noreply, show_qr(state)}
    end
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
    state = render(state)
    {:noreply, state}
  end

  # --- QR mode ends -----------------------------------------------------------

  @impl true
  def handle_info(:qr_end, state) do
    Logger.info("[Display.Renderer] QR mode ended — resuming flights")

    state =
      %{state | mode: if(state.flights == [], do: :loading, else: :flights), qr_timer: nil}

    state = ensure_cycle_timer(state)
    state = render(state)
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

  defp render(state) do
    command = build_command(state)

    cond do
      command == :noop ->
        state

      command == state.last_command ->
        state

      true ->
        Driver.send_command(command)
        %{state | last_command: command}
    end
  end

  defp build_command(%{mode: :loading}), do: %{cmd: "scan_anim"}

  defp build_command(%{mode: :ap}), do: %{cmd: "ap_screen", ssid: @ap_ssid, ip: @ap_ip}

  defp build_command(%{mode: :connecting, connecting_ssid: ssid}),
    do: %{cmd: "connecting_screen", ssid: ssid || "WiFi"}

  defp build_command(%{mode: :disconnected}), do: %{cmd: "wifi_error"}

  defp build_command(%{mode: :qr}) do
    ip = NetworkManager.current_ip() || "aerovision.local"
    url = "http://#{ip}"
    Logger.debug("[Display.Renderer] Showing QR for #{url}")
    %{cmd: "qr", data: url}
  end

  defp build_command(%{mode: :flights, flights: [], current_index: _}),
    do: build_command(%{mode: :loading})

  defp build_command(%{mode: :flights, flights: flights, current_index: index}) do
    flight = Enum.at(flights, index)
    build_flight_card(flight)
  end

  defp build_command(_state), do: :noop

  # ---------------------------------------------------------------------------
  # Flight card builder
  # ---------------------------------------------------------------------------

  defp build_flight_card(flight) do
    sv = flight.state_vector
    fi = flight.flight_info
    timezone = Store.get(:timezone)

    %{
      cmd: "flight_card",
      airline: airline_name(fi),
      operator: derive_operator(fi, sv),
      flight: flight_ident(fi, sv),
      aircraft: aircraft_type(fi, sv),
      route_origin: airport_code(fi && fi.origin),
      route_dest: airport_code(fi && fi.destination),
      altitude_ft: sv.baro_altitude |> safe_round(),
      speed_kt: sv.velocity |> safe_round(),
      bearing_deg: sv.true_track |> safe_round(),
      vrate_fpm: sv.vertical_rate |> safe_round(),
      dep_time: format_time(fi && fi.departure_time, timezone),
      arr_time: format_time(fi && fi.arrival_time, timezone),
      progress: (fi && fi.progress_pct) || 0.0,
      airline_color: [0, 200, 220]
    }
  end

  defp airline_name(nil), do: nil
  defp airline_name(fi), do: fi.airline_name |> truncate(7) |> upcase_safe()

  defp flight_ident(nil, sv), do: sv.callsign
  defp flight_ident(fi, sv), do: fi.ident || sv.callsign

  defp aircraft_type(nil, sv), do: AircraftCodes.abbreviate(sv.aircraft_type_name) || "---"

  defp aircraft_type(fi, sv),
    do: fi.aircraft_type || AircraftCodes.abbreviate(sv.aircraft_type_name) || "---"

  defp airport_code(nil), do: nil
  defp airport_code(airport), do: airport.iata || airport.icao

  defp upcase_safe(nil), do: nil
  defp upcase_safe(str), do: String.upcase(str)

  # Extract ICAO airline operator code. Prefer FlightInfo.operator if available,
  # otherwise extract the leading 2-3 letter ICAO prefix from the ADS-B callsign
  # (e.g., "DAL" from "DAL1192"). This is used by the Go LED driver for logo lookup.
  defp derive_operator(%{operator: op}, _sv) when is_binary(op) and op != "", do: op

  defp derive_operator(_fi, %{callsign: cs}) when is_binary(cs) do
    case Regex.run(~r/^([A-Z]{2,3})\d/, cs) do
      [_, prefix] -> prefix
      _ -> nil
    end
  end

  defp derive_operator(_, _), do: nil

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  @doc "Format a DateTime as HH:MM in the given timezone. Returns \"--:--\" if nil."
  def format_time(nil, _timezone), do: "--:--"

  def format_time(%DateTime{} = dt, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> Calendar.strftime(shifted, "%H:%M")
      {:error, _} -> Calendar.strftime(dt, "%H:%M")
    end
  end

  @doc "Format a DateTime as HH:MM using the configured timezone. Returns \"--:--\" if nil."
  def format_time(nil), do: "--:--"

  def format_time(%DateTime{} = dt) do
    format_time(dt, Store.get(:timezone))
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

  defp cancel_qr_timer(%{qr_timer: nil} = state), do: state

  defp cancel_qr_timer(%{qr_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | qr_timer: nil}
  end

  defp show_qr(state) do
    state = cancel_qr_timer(state)
    qr_ref = Process.send_after(self(), :qr_end, @qr_duration_ms)
    state = %{state | mode: :qr, qr_timer: qr_ref}
    render(state)
  end
end
