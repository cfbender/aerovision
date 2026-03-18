defmodule AeroVision.Display.Driver do
  @moduledoc """
  Manages the Go `led_driver` binary as an Elixir Port.

  Sends JSON commands (length-prefixed via `{:packet, 4}`) to the Go process,
  which renders frames on the 64×64 RGB LED matrix.

  ## Dev mode
  If the `led_driver` binary doesn't exist at the expected path, the driver
  starts in no-op mode: all `send_command/1` calls are silently dropped and
  `alive?/0` returns `false`. This lets the application run on a development
  host without hardware.

  """

  use GenServer

  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Asynchronously send a command map to the Go binary (fire-and-forget)."
  def send_command(command_map) do
    GenServer.cast(__MODULE__, {:send_command, command_map})
  end

  @doc """
  Synchronously send a command map to the Go binary and wait for a response.

  Times out after 5 seconds.
  """
  def send_command_sync(command_map, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:send_command_sync, command_map}, timeout)
  end

  @doc "Returns `true` if the Go port process is running."
  def alive? do
    GenServer.call(__MODULE__, :alive?)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    path = Application.app_dir(:aerovision, "priv/led_driver")

    {port, alive} =
      if File.exists?(path) do
        Logger.info("[Display.Driver] Starting led_driver at #{path}")
        port = open_port(path)
        {port, true}
      else
        Logger.warning("[Display.Driver] led_driver binary not found at #{path} — running in no-op mode")

        {nil, false}
      end

    state = %{
      port: port,
      pending_calls: %{},
      alive: alive
    }

    host? = Application.get_env(:aerovision, :target, :host) == :host

    if alive and not host? do
      # Disable the Linux RT scheduler throttle after the hzeller library
      # has initialized. hzeller's DisableRealtimeThrottling() writes 990000
      # during NewMatrix(), which throttles the refresh thread for 10ms every
      # second causing a visible blink. We override it to -1 (no throttle)
      # after a short delay to ensure the library has finished init.
      Process.send_after(self(), :disable_rt_throttle, 2_000)
    end

    {:ok, state}
  end

  # --- Async cast: send_command ------------------------------------------------

  @impl true
  def handle_cast({:send_command, command_map}, %{alive: false} = state) do
    # Real port is in no-op mode, but still broadcast so PreviewServer renders
    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "display_commands",
      {:display_command, command_map}
    )

    {:noreply, state}
  end

  def handle_cast({:send_command, command_map}, state) do
    state = safe_send_to_port(state, command_map)

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "display_commands",
      {:display_command, command_map}
    )

    {:noreply, state}
  end

  # --- Sync call: send_command_sync --------------------------------------------

  @impl true
  def handle_call({:send_command_sync, _command_map}, _from, %{alive: false} = state) do
    {:reply, {:error, :no_op_mode}, state}
  end

  def handle_call({:send_command_sync, command_map}, from, state) do
    ref = make_ref()

    try do
      send_to_port(state.port, Map.put(command_map, :__ref__, inspect(ref)))
      pending = Map.put(state.pending_calls, ref, from)
      {:noreply, %{state | pending_calls: pending}}
    rescue
      ArgumentError ->
        Logger.warning("[Display.Driver] Port died during sync send — degrading to no-op mode")
        Process.send_after(self(), :retry_port, 5_000)
        {:reply, {:error, :port_died}, %{state | port: nil, alive: false}}
    end
  end

  # --- Sync call: alive? -------------------------------------------------------

  @impl true
  def handle_call(:alive?, _from, state) do
    {:reply, state.alive, state}
  end

  # --- Port messages -----------------------------------------------------------

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, response} ->
        case Map.get(response, "status") do
          status when status in ["ok", "frame"] ->
            :ok

          "refresh_rate" ->
            Logger.info("[Display.Driver] Refresh rate: #{Map.get(response, "hz")} Hz")

          _other ->
            Logger.debug("[Display.Driver] Response from led_driver: #{inspect(response)}")
        end

        state = maybe_resolve_pending_call(response, state)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Display.Driver] Failed to decode response: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("[Display.Driver] led_driver exited with status #{status} — degrading to no-op mode, retrying in 5s")

    Process.send_after(self(), :retry_port, 5_000)
    {:noreply, %{state | port: nil, alive: false}}
  end

  # --- Port retry ----------------------------------------------------------------

  @impl true
  def handle_info(:retry_port, %{alive: true} = state) do
    # Already running again (e.g. concurrent retry messages) — ignore
    {:noreply, state}
  end

  def handle_info(:retry_port, state) do
    path = Application.app_dir(:aerovision, "priv/led_driver")

    if File.exists?(path) do
      Logger.info("[Display.Driver] Retrying led_driver at #{path}")

      try do
        port = open_port(path)
        {:noreply, %{state | port: port, alive: true}}
      rescue
        e ->
          Logger.error("[Display.Driver] Retry failed: #{inspect(e)} — will retry in 5s")
          Process.send_after(self(), :retry_port, 5_000)
          {:noreply, state}
      end
    else
      Logger.warning("[Display.Driver] led_driver binary not found — staying in no-op mode")
      {:noreply, state}
    end
  end

  # --- RT throttle disable -----------------------------------------------------

  @impl true
  def handle_info(:disable_rt_throttle, state) do
    case File.write("/proc/sys/kernel/sched_rt_runtime_us", "-1") do
      :ok ->
        Logger.info("[Display.Driver] Disabled RT scheduler throttle (sched_rt_runtime_us = -1)")

      {:error, reason} ->
        Logger.warning("[Display.Driver] Could not disable RT scheduler throttle: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # --- Catch-all ---------------------------------------------------------------

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Display.Driver] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp open_port(path) do
    display_cfg = Application.get_env(:aerovision, :display, [])

    rows = Keyword.get(display_cfg, :rows, 64)
    cols = Keyword.get(display_cfg, :cols, 64)
    chain = Keyword.get(display_cfg, :chain_length, 1)
    parallel = Keyword.get(display_cfg, :parallel, 1)
    brightness = Keyword.get(display_cfg, :brightness, 80)
    gpio_mapping = Keyword.get(display_cfg, :gpio_mapping, "regular")
    slowdown = Keyword.get(display_cfg, :slowdown_gpio, 1)
    limit_refresh = Keyword.get(display_cfg, :limit_refresh_hz, 0)
    no_hw_pulse = Keyword.get(display_cfg, :no_hardware_pulse, true)
    pwm_bits = Keyword.get(display_cfg, :pwm_bits, 11)
    pwm_lsb_ns = Keyword.get(display_cfg, :pwm_lsb_nanoseconds, 130)
    pwm_dither_bits = Keyword.get(display_cfg, :pwm_dither_bits, 0)
    show_refresh = Keyword.get(display_cfg, :show_refresh_rate, false)

    args =
      [
        "--led-rows=#{rows}",
        "--led-cols=#{cols}",
        "--led-chain=#{chain}",
        "--led-parallel=#{parallel}",
        "--led-brightness=#{brightness}",
        "--led-gpio-mapping=#{gpio_mapping}",
        "--led-slowdown-gpio=#{slowdown}",
        "--led-pwm-bits=#{pwm_bits}",
        "--led-pwm-lsb-nanoseconds=#{pwm_lsb_ns}",
        "--led-pwm-dither-bits=#{pwm_dither_bits}"
      ] ++
        if(no_hw_pulse, do: ["--led-no-hardware-pulse"], else: []) ++
        if(limit_refresh > 0, do: ["--led-limit-refresh=#{limit_refresh}"], else: []) ++
        if(show_refresh, do: ["--led-show-refresh"], else: [])

    Port.open(
      {:spawn_executable, path},
      [:binary, :exit_status, {:packet, 4}, {:args, args}]
    )
  end

  defp safe_send_to_port(%{alive: false} = state, _command_map), do: state

  defp safe_send_to_port(%{port: port} = state, command_map) do
    send_to_port(port, command_map)
    state
  rescue
    ArgumentError ->
      Logger.warning("[Display.Driver] Port died during send — degrading to no-op mode")
      Process.send_after(self(), :retry_port, 5_000)
      %{state | port: nil, alive: false}
  end

  defp send_to_port(port, command_map) do
    case Jason.encode(command_map) do
      {:ok, json} ->
        Port.command(port, json)

      {:error, reason} ->
        Logger.error("[Display.Driver] Failed to encode command: #{inspect(reason)}")
    end
  end

  # If the response contains a `__ref__` field matching a pending call, resolve it.
  defp maybe_resolve_pending_call(%{"__ref__" => ref_str} = response, state) do
    matching =
      Enum.find(state.pending_calls, fn {ref, _from} -> inspect(ref) == ref_str end)

    case matching do
      {ref, from} ->
        GenServer.reply(from, {:ok, response})
        %{state | pending_calls: Map.delete(state.pending_calls, ref)}

      nil ->
        state
    end
  end

  defp maybe_resolve_pending_call(_response, state), do: state
end
