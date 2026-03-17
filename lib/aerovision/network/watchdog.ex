defmodule AeroVision.Network.Watchdog do
  @moduledoc """
  Network accessibility watchdog.

  Starts a countdown timer on boot. If no LiveView client connects within
  the timeout window, forces AP mode so the device is always recoverable
  via the "AeroVision-Setup" WiFi network.

  Once a client connects, the watchdog disarms permanently for this boot
  cycle. It only runs on target hardware — on host/test it starts in
  disarmed mode.
  """

  use GenServer
  require Logger

  @timeout_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Signal that a client has connected (call from LiveView mount)."
  def ping do
    GenServer.cast(__MODULE__, :ping)
  end

  @impl true
  def init(_opts) do
    if on_target?() do
      Logger.info(
        "[Watchdog] Armed — will force AP mode in #{div(@timeout_ms, 60_000)} minutes if no client connects"
      )

      timer = Process.send_after(self(), :timeout, @timeout_ms)
      {:ok, %{timer: timer, armed: true}}
    else
      {:ok, %{timer: nil, armed: false}}
    end
  end

  @impl true
  def handle_cast(:ping, %{armed: true, timer: timer} = state) do
    Logger.info("[Watchdog] Client connected — disarming")
    if timer, do: Process.cancel_timer(timer)
    {:noreply, %{state | timer: nil, armed: false}}
  end

  def handle_cast(:ping, state) do
    # Already disarmed
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, %{armed: true} = state) do
    Logger.warning("[Watchdog] No client connected within timeout — forcing AP mode for recovery")

    AeroVision.Network.Manager.force_ap_mode()
    {:noreply, %{state | timer: nil, armed: false}}
  end

  def handle_info(:timeout, state) do
    # Stale timer after disarm
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp on_target? do
    target = Application.get_env(:aerovision, :target, :host)
    target != :host and target != :test
  end
end
