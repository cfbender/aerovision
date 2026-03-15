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

  ## Health check
  A `{"cmd":"ping"}` command is sent every 30 seconds. If no response arrives
  within 5 seconds, a warning is logged (but no automatic restart is triggered —
  the supervisor handles that when the port actually exits).
  """

  use GenServer
  require Logger

  @ping_interval_ms 30_000
  @ping_timeout_ms 5_000

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
        Logger.warning(
          "[Display.Driver] led_driver binary not found at #{path} — running in no-op mode"
        )

        {nil, false}
      end

    state = %{
      port: port,
      pending_calls: %{},
      alive: alive
    }

    if alive do
      schedule_ping()
    end

    {:ok, state}
  end

  # --- Async cast: send_command ------------------------------------------------

  @impl true
  def handle_cast({:send_command, _command_map}, %{alive: false} = state) do
    # No-op mode — silently drop
    {:noreply, state}
  end

  def handle_cast({:send_command, command_map}, state) do
    send_to_port(state.port, command_map)
    {:noreply, state}
  end

  # --- Sync call: send_command_sync --------------------------------------------

  @impl true
  def handle_call({:send_command_sync, _command_map}, _from, %{alive: false} = state) do
    {:reply, {:error, :no_op_mode}, state}
  end

  def handle_call({:send_command_sync, command_map}, from, state) do
    ref = make_ref()
    send_to_port(state.port, Map.put(command_map, :__ref__, inspect(ref)))
    pending = Map.put(state.pending_calls, ref, from)
    {:noreply, %{state | pending_calls: pending}}
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
        Logger.debug("[Display.Driver] Response from led_driver: #{inspect(response)}")
        state = maybe_resolve_pending_call(response, state)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Display.Driver] Failed to decode response: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("[Display.Driver] led_driver exited with status #{status} — letting supervisor restart")
    # Fail the GenServer so the supervisor can restart us (and the port)
    {:stop, {:port_exited, status}, %{state | port: nil, alive: false}}
  end

  # --- Health-check ping -------------------------------------------------------

  def handle_info(:ping, %{alive: false} = state) do
    {:noreply, state}
  end

  def handle_info(:ping, state) do
    send_to_port(state.port, %{cmd: "ping"})
    Process.send_after(self(), :ping_timeout, @ping_timeout_ms)
    schedule_ping()
    {:noreply, state}
  end

  def handle_info(:ping_timeout, state) do
    # We don't track whether a pong arrived; just log a warning.
    Logger.warning("[Display.Driver] Ping timeout — led_driver may be unresponsive")
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

    args = [
      "--led-rows=#{rows}",
      "--led-cols=#{cols}",
      "--led-chain=#{chain}",
      "--led-parallel=#{parallel}",
      "--led-brightness=#{brightness}",
      "--led-gpio-mapping=#{gpio_mapping}",
      "--led-no-hardware-pulse",
      "--led-slowdown-gpio=#{slowdown}"
    ]

    Port.open(
      {:spawn_executable, path},
      [:binary, :exit_status, {:packet, 4}, {:args, args}]
    )
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

  defp schedule_ping do
    Process.send_after(self(), :ping, @ping_interval_ms)
  end
end
