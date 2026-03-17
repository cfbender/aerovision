defmodule AeroVision.Flight.FlightInfo do
  @moduledoc "Enriched flight information from Skylink Flight Status API."

  defstruct [
    # String - flight identifier (e.g., "AAL1234")
    :ident,
    # String - operator ICAO code (e.g., "AAL")
    :operator,
    # String - human-friendly airline name
    :airline_name,
    # String - ICAO aircraft type code (e.g., "B738")
    :aircraft_type,
    # String - human-friendly aircraft name (e.g., "Boeing 737-800")
    :aircraft_name,
    # %Airport{}
    :origin,
    # %Airport{}
    :destination,
    # DateTime | nil - scheduled departure (scheduled_out)
    :departure_time,
    # DateTime | nil - actual departure (actual_out), preferred for progress
    :actual_departure_time,
    # DateTime | nil - scheduled arrival (scheduled_in)
    :arrival_time,
    # String | nil - "En Route", "Landed", "Scheduled"
    :status,
    # float 0.0-1.0 | nil
    :progress_pct,
    # DateTime - when this was cached
    :cached_at
  ]

  @type t :: %__MODULE__{}
end

defmodule AeroVision.Flight.Airport do
  @moduledoc "Airport information."

  defstruct [
    # String - ICAO code (e.g., "KRDU")
    :icao,
    # String - IATA code (e.g., "RDU")
    :iata,
    # String - airport name
    :name,
    # String - city name
    :city
  ]

  @type t :: %__MODULE__{}
end
