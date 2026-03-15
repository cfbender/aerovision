defmodule AeroVision.GPIO.Button do
  @moduledoc """
  GPIO button input handler for AeroVision.

  Listens on a configurable GPIO pin (default 26) configured as an active-low
  input with a pull-up resistor. Detects short and long presses with 50 ms
  debounce:

  - **Short press** (< 1 s): broadcasts `{:button, :short_press}` on PubSub
    topic `"gpio"` → triggers QR code display.
  - **Long press** (≥ 3 s): broadcasts `{:button, :long_press}` on topic
    `"gpio"` and calls `AeroVision.Network.Manager.force_ap_mode/0`.

  ## Host mode
  If `Circuits.GPIO` is not available (running on a development host), the
  GenServer starts successfully but takes no GPIO action.
  """

  use GenServer
  require Logger

  alias AeroVision.Network.Manager, as: NetworkManager

  @pubsub AeroVision.PubSub
  @topic "gpio"

  @default_pin 26
  @debounce_ms 50
  @short_press_max_ms 1_000
  @long_press_min_ms 3_000

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
  def init(opts) do
    pin = Keyword.get(opts, :pin, @default_pin)

    state = %{
      gpio: nil,
      press_start: nil,
      last_event: 0
    }

    case open_gpio(pin) do
      {:ok, gpio} ->
        Logger.info("[GPIO.Button] Listening on GPIO pin #{pin}")
        {:ok, %{state | gpio: gpio}}

      {:error, reason} ->
        Logger.warning(
          "[GPIO.Button] Could not open GPIO pin #{pin}: #{inspect(reason)} — running in no-op mode"
        )

        {:ok, state}

      :not_available ->
        Logger.info("[GPIO.Button] Circuits.GPIO not available — running in no-op mode (host)")
        {:ok, state}
    end
  end

  # --- GPIO interrupt ----------------------------------------------------------

  # Circuits.GPIO sends: {:circuits_gpio, pin, timestamp, value}
  # value=0 → button pressed (active-low), value=1 → released
  @impl true
  def handle_info({:circuits_gpio, _pin, _timestamp, value}, state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_event < @debounce_ms do
      # Within debounce window — ignore
      {:noreply, state}
    else
      state = %{state | last_event: now}
      state = handle_gpio_value(value, now, state)
      {:noreply, state}
    end
  end

  # --- Catch-all ---------------------------------------------------------------

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[GPIO.Button] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Button pressed (active-low: GPIO goes LOW = 0)
  defp handle_gpio_value(0, now, state) do
    Logger.debug("[GPIO.Button] Button pressed at #{now}")
    %{state | press_start: now}
  end

  # Button released (GPIO goes HIGH = 1)
  defp handle_gpio_value(1, _now, %{press_start: nil} = state) do
    # Released without a recorded press — ignore (e.g. spurious interrupt)
    Logger.debug("[GPIO.Button] Release event with no press_start recorded — ignored")
    state
  end

  defp handle_gpio_value(1, now, %{press_start: press_start} = state) do
    held_ms = now - press_start
    Logger.debug("[GPIO.Button] Button released — held #{held_ms}ms")

    cond do
      held_ms < @short_press_max_ms ->
        Logger.info("[GPIO.Button] Short press detected (#{held_ms}ms)")
        broadcast(:short_press)

      held_ms >= @long_press_min_ms ->
        Logger.info("[GPIO.Button] Long press detected (#{held_ms}ms) — forcing AP mode")
        broadcast(:long_press)
        NetworkManager.force_ap_mode()

      true ->
        Logger.debug("[GPIO.Button] Medium press (#{held_ms}ms) — ignored")
    end

    %{state | press_start: nil}
  end

  defp handle_gpio_value(value, _now, state) do
    Logger.debug("[GPIO.Button] Unexpected GPIO value: #{value}")
    state
  end

  defp broadcast(press_type) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:button, press_type})
  end

  # ---------------------------------------------------------------------------
  # Circuits.GPIO wrapper (target-safe)
  # ---------------------------------------------------------------------------

  defp open_gpio(pin) do
    if circuits_gpio_available?() do
      case Circuits.GPIO.open(pin, :input, pull_mode: :pullup) do
        {:ok, gpio} ->
          case Circuits.GPIO.set_interrupts(gpio, :both) do
            :ok ->
              {:ok, gpio}

            {:error, reason} ->
              Circuits.GPIO.close(gpio)
              {:error, {:set_interrupts_failed, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_available
    end
  end

  defp circuits_gpio_available? do
    Code.ensure_loaded?(Circuits.GPIO)
  rescue
    _ -> false
  end
end
