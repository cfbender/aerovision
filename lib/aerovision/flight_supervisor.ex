defmodule AeroVision.FlightSupervisor do
  @moduledoc """
  Supervisor for the flight data pipeline.

  Manages all flight data source processes under a `one_for_one` strategy,
  meaning each source (Cache instances, FlightStatus, Skylink ADSB, OpenSky,
  Tracker) is independent — a crash in one does not restart the others.

  Two Cache instances are started:
    - `:flight_cache` — ETS-backed cache with TTL for enriched FlightInfo
    - `:tracker_cache` — CubDB-backed persistent cache for Tracker state

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
      Supervisor.child_spec(
        {AeroVision.Cache,
         name: :flight_cache,
         data_dir: "skylink_cache",
         cache_version: 2,
         ets: true,
         ttl: 86_400,
         prune_interval: 86_400_000},
        id: :flight_cache
      ),
      Supervisor.child_spec(
        {AeroVision.Cache,
         id: :tracker_cache,
         name: :tracker_cache,
         data_dir: "tracker_cache",
         cache_version: 2,
         cubdb_opts: [auto_compact: {10, 0.3}]},
        id: :tracker_cache
      ),
      AeroVision.Flight.FlightStatus,
      AeroVision.Flight.Providers.Skylink.ADSB,
      AeroVision.Flight.Providers.OpenSky,
      AeroVision.Flight.Tracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
