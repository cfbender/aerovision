defmodule AeroVision.Application do
  @moduledoc """
  AeroVision OTP Application.

  Supervision tree for the flight tracking LED display system.
  """
  use Application

  alias AeroVision.Network.Manager
  alias AeroVision.Network.Watchdog

  require Logger

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: AeroVision.Supervisor]

    children =
      [
        # PubSub for inter-process communication
        {Phoenix.PubSub, name: AeroVision.PubSub},
        # Persistent configuration storage
        AeroVision.Config.Store,
        # Telemetry
        AeroVisionWeb.Telemetry
      ] ++
        target_children(target())

    result = Supervisor.start_link(children, opts)
    log_boot_info()
    result
  end

  # In test mode, start only the bare minimum — tests manage their own processes.
  defp target_children(:test), do: []

  defp target_children(:host) do
    [
      # Network manager (safe on host — VintageNet calls are no-ops)
      Manager,
      # Flight data pipeline (independent sources; a single-source crash stays contained)
      AeroVision.FlightSupervisor,
      # Hardware subsystem (Driver → PreviewServer → Renderer → Button via rest_for_one)
      AeroVision.HardwareSupervisor,
      # Phoenix endpoint for development — isolated from hardware/flight crashes
      AeroVisionWeb.Endpoint,
      # Network watchdog — forces AP mode if no client connects within timeout (no-op on host)
      Watchdog
    ]
  end

  defp target_children(_target) do
    [
      # Network management (WiFi + AP fallback)
      Manager,
      # Flight data pipeline (independent sources; a single-source crash stays contained)
      AeroVision.FlightSupervisor,
      # Hardware subsystem (Driver → Renderer → Button via rest_for_one)
      AeroVision.HardwareSupervisor,
      # Phoenix endpoint — isolated from hardware/flight crashes
      AeroVisionWeb.Endpoint,
      # Network watchdog — forces AP mode if no client connects within timeout
      Watchdog
    ]
  end

  defp target do
    Application.get_env(:aerovision, :target, :host)
  end

  defp log_boot_info do
    Logger.info("""
    [AeroVision] ======================================
    [AeroVision] Booted — v#{Application.spec(:aerovision, :vsn)}
    [AeroVision] Target: #{Application.get_env(:aerovision, :target, :host)}
    [AeroVision] ======================================
    """)

    if target() not in [:host, :test] do
      Task.start(fn ->
        Process.sleep(5_000)
        log_network_status()
      end)
    end
  end

  defp log_network_status do
    for iface <- ["wlan0", "eth0", "usb0"] do
      connection = VintageNet.get(["interface", iface, "connection"])
      addresses = VintageNet.get(["interface", iface, "addresses"])

      ips =
        case addresses do
          addrs when is_list(addrs) ->
            addrs
            |> Enum.filter(&match?(%{family: :inet}, &1))
            |> Enum.map_join(", ", fn %{address: addr} -> addr |> :inet.ntoa() |> to_string() end)

          _ ->
            "none"
        end

      Logger.info("[AeroVision] #{iface}: #{connection || "not configured"} — IPs: #{ips}")
    end
  rescue
    e -> Logger.warning("[AeroVision] Could not log network status: #{inspect(e)}")
  end

  @impl true
  def config_change(changed, _new, removed) do
    AeroVisionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
