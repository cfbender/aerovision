defmodule AeroVision.Network.Watchdog do
  @moduledoc """
  Network accessibility watchdog.

  Starts a countdown timer on boot. If internet is not accessible within
  the timeout window, forces AP mode so the device is always recoverable
  via the "AeroVision-Setup" WiFi network.

  Once a connection succeeds, the watchdog disarms permanently for this boot
  cycle. It only runs on target hardware — on host/test it starts in
  disarmed mode.
  """

  use GenServer

  require Logger

  @timeout_ms to_timeout(minute: 5)
  @ping_interval_ms to_timeout(second: 30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if on_target?() do
      Logger.info(
        "[Watchdog] Armed — will force AP mode in #{div(@timeout_ms, 60_000)} minutes if no connection succeeds"
      )

      ping_timer = Process.send_after(self(), :ping, @ping_interval_ms)
      timeout_timer = Process.send_after(self(), :timeout, @timeout_ms)
      {:ok, %{timeout_timer: timeout_timer, ping_timer: ping_timer, armed: true, ping_cache: %{}}}
    else
      {:ok, %{timeout_timer: nil, ping_timer: nil, armed: false, ping_cache: %{}}}
    end
  end

  @impl true
  def handle_cast(:disarm, %{armed: true} = state) do
    Logger.info("[Watchdog] Disarming")
    if state.timeout_timer, do: Process.cancel_timer(state.timeout_timer)
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    {:noreply, %{state | timeout_timer: nil, ping_timer: nil, armed: false}}
  end

  def handle_cast(:disarm, state) do
    # Already disarmed
    {:noreply, state}
  end

  def handle_cast(:ping, %{armed: false} = state), do: {:noreply, state}

  def handle_cast(:ping, state) do
    cache = state.ping_cache

    Task.start(fn ->
      {status, new_cache} = VintageNet.Connectivity.Inspector.check_internet("wlan0", cache)
      send(__MODULE__, {:ping_result, status, new_cache})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:ping, state), do: handle_cast(:ping, state)

  def handle_info(:timeout, %{armed: true} = state) do
    Logger.warning("[Watchdog] No connection succeeded within timeout — forcing AP mode for recovery")
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)

    AeroVision.Network.Manager.force_ap_mode()
    {:noreply, %{state | timeout_timer: nil, ping_timer: nil, armed: false}}
  end

  def handle_info(:timeout, state) do
    # Stale timer after disarm
    {:noreply, state}
  end

  def handle_info({:ping_result, :internet, _cache}, state) do
    GenServer.cast(__MODULE__, :disarm)
    {:noreply, state}
  end

  def handle_info({:ping_result, _status, new_cache}, state) do
    Logger.warning("[Watchdog] Ping failed — still waiting for connection")
    Process.send_after(__MODULE__, :ping, @ping_interval_ms)
    {:noreply, %{state | ping_cache: new_cache}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp on_target? do
    target = Application.get_env(:aerovision, :target, :host)
    target != :host and target != :test
  end
end
