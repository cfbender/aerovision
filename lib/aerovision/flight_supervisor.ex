defmodule AeroVision.FlightSupervisor do
  @moduledoc """
  Supervisor for the flight data pipeline.

  Manages all flight data source processes under a `one_for_one` strategy,
  meaning each source (Skylink FlightStatus, Skylink ADSB, OpenSky, Tracker)
  is independent — a crash in one does not restart the others.

  This subtree is intentionally isolated from the hardware and web subtrees so
  that a flaky upstream data source cannot affect the Phoenix endpoint or the
  display hardware.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      AeroVision.Flight.Skylink.FlightStatus,
      AeroVision.Flight.Skylink.ADSB,
      AeroVision.Flight.OpenSky,
      AeroVision.Flight.Tracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
