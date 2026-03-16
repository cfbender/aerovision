defmodule AeroVision.Application do
  @moduledoc """
  AeroVision OTP Application.

  Supervision tree for the flight tracking LED display system.
  """
  use Application

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

    Supervisor.start_link(children, opts)
  end

  # In test mode, start only the bare minimum — tests manage their own processes.
  defp target_children(:test), do: []

  defp target_children(:host) do
    [
      # Network manager (safe on host — VintageNet calls are no-ops)
      AeroVision.Network.Manager,
      # Flight data pipeline (works on host for development)
      AeroVision.Flight.AeroAPI,
      AeroVision.Flight.OpenSky,
      AeroVision.Flight.Tracker,
      # Phoenix endpoint for development
      AeroVisionWeb.Endpoint
    ]
  end

  defp target_children(_target) do
    [
      # Network management (WiFi + AP fallback)
      AeroVision.Network.Manager,
      # Flight data pipeline
      AeroVision.Flight.AeroAPI,
      AeroVision.Flight.OpenSky,
      AeroVision.Flight.Tracker,
      # Display subsystem
      AeroVision.Display.Driver,
      AeroVision.Display.Renderer,
      # GPIO button input
      AeroVision.GPIO.Button,
      # Phoenix endpoint
      AeroVisionWeb.Endpoint
    ]
  end

  defp target do
    Application.get_env(:aerovision, :target, :host)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AeroVisionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
