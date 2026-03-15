defmodule AeroVision.Flight.FlightInfo do
  @moduledoc "Enriched flight information from FlightAware AeroAPI."

  defstruct [
    :ident,              # String - flight identifier (e.g., "AAL1234")
    :operator,           # String - operator ICAO code (e.g., "AAL")
    :airline_name,       # String - human-friendly airline name
    :aircraft_type,      # String - ICAO aircraft type code (e.g., "B738")
    :aircraft_name,      # String - human-friendly aircraft name (e.g., "Boeing 737-800")
    :origin,             # %Airport{}
    :destination,        # %Airport{}
    :departure_time,     # DateTime | nil
    :arrival_time,       # DateTime | nil
    :progress_pct,       # float 0.0-1.0 | nil
    :cached_at           # DateTime - when this was cached
  ]

  @type t :: %__MODULE__{}
end

defmodule AeroVision.Flight.Airport do
  @moduledoc "Airport information."

  defstruct [
    :icao,    # String - ICAO code (e.g., "KRDU")
    :iata,    # String - IATA code (e.g., "RDU")
    :name,    # String - airport name
    :city     # String - city name
  ]

  @type t :: %__MODULE__{}
end
