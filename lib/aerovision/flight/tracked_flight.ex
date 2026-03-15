defmodule AeroVision.Flight.TrackedFlight do
  @moduledoc "A tracked flight combining ADS-B state with enriched info."

  defstruct [
    :state_vector,    # %StateVector{} - current ADS-B data
    :flight_info,     # %FlightInfo{} | nil - enriched data (may not be available yet)
    :first_seen_at,   # DateTime
    :last_seen_at     # DateTime
  ]

  @type t :: %__MODULE__{
    state_vector: AeroVision.Flight.StateVector.t(),
    flight_info: AeroVision.Flight.FlightInfo.t() | nil,
    first_seen_at: DateTime.t(),
    last_seen_at: DateTime.t()
  }
end
