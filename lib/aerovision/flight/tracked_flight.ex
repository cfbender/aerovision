defmodule AeroVision.Flight.TrackedFlight do
  @moduledoc "A tracked flight combining ADS-B state with enriched info."

  defstruct [
    # %StateVector{} - current ADS-B data
    :state_vector,
    # %FlightInfo{} | nil - enriched data (may not be available yet)
    :flight_info,
    # DateTime
    :first_seen_at,
    # DateTime
    :last_seen_at
  ]

  @type t :: %__MODULE__{
          state_vector: AeroVision.Flight.StateVector.t(),
          flight_info: AeroVision.Flight.FlightInfo.t() | nil,
          first_seen_at: DateTime.t(),
          last_seen_at: DateTime.t()
        }
end
