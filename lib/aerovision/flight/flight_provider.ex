defmodule AeroVision.Flight.FlightProvider do
  @moduledoc """
  Behaviour for flight data providers.

  Each provider must implement `fetch/1` to look up enrichment data for an
  ADS-B callsign and `name/0` to return a human-readable provider name for
  logging.
  """

  alias AeroVision.Flight.FlightInfo

  @doc "Fetch flight enrichment data for the given callsign."
  @callback fetch(callsign :: String.t()) :: {:ok, FlightInfo.t()} | {:error, term()}

  @doc "Human-readable name of this provider, used in log messages."
  @callback name() :: String.t()
end
