defmodule AeroVision.Display.PreviewServer do
  @moduledoc """
  Spawns the LED driver binary in preview-pixels mode and relays display
  commands to it. Each rendered frame is received back as a flat JSON array of
  [r,g,b] triples, then broadcast on PubSub topic "preview" for the
  PreviewLive page.

  Only active on the host — on a real Nerves target the preview page is not
  needed (you have the physical display).
  """

  use GenServer

  require Logger

  @pubsub AeroVision.PubSub
  @commands_topic "display_commands"
  @preview_topic "preview"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the last pixel data array, or nil if no frame received yet."
  def get_last_pixels do
    GenServer.call(__MODULE__, :get_last_pixels)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @commands_topic)

    path = Application.app_dir(:aerovision, "priv/led_driver")

    {port, alive} =
      if File.exists?(path) do
        Logger.info("[PreviewServer] Starting led_driver in preview-pixels mode")
        port = open_preview_port(path)
        {port, true}
      else
        Logger.warning("[PreviewServer] led_driver binary not found — preview disabled")
        {nil, false}
      end

    {:ok, %{port: port, alive: alive, last_pixels: nil}}
  end

  @impl true
  def handle_call(:get_last_pixels, _from, state) do
    {:reply, Map.get(state, :last_pixels), state}
  end

  # Relay display commands to the preview port
  @impl true
  def handle_info({:display_command, _cmd}, %{alive: false} = state) do
    {:noreply, state}
  end

  def handle_info({:display_command, cmd}, state) do
    case Jason.encode(cmd) do
      {:ok, json} ->
        Port.command(state.port, json)

      {:error, reason} ->
        Logger.warning("[PreviewServer] Failed to encode command: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Receive rendered frame from the preview port
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state =
      case Jason.decode(data) do
        {:ok, %{"status" => "pixels", "pixels" => pixels}} ->
          Phoenix.PubSub.broadcast(@pubsub, @preview_topic, {:preview_pixels, pixels})
          %{state | last_pixels: pixels}

        {:ok, _other} ->
          state

        {:error, _} ->
          Logger.debug("[PreviewServer] Non-JSON data from port: #{inspect(data)}")
          state
      end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("[PreviewServer] led_driver preview process exited with status #{status} — degrading to no-op mode")

    {:noreply, %{state | port: nil, alive: false}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Port helpers
  # ---------------------------------------------------------------------------

  defp open_preview_port(path) do
    display_cfg = Application.get_env(:aerovision, :display, [])
    rows = Keyword.get(display_cfg, :rows, 64)
    cols = Keyword.get(display_cfg, :cols, 64)
    brightness = Keyword.get(display_cfg, :brightness, 80)

    args = [
      "--led-rows=#{rows}",
      "--led-cols=#{cols}",
      "--led-brightness=#{brightness}",
      "--preview-pixels"
    ]

    Port.open(
      {:spawn_executable, path},
      [:binary, :exit_status, {:packet, 4}, {:args, args}]
    )
  end
end
