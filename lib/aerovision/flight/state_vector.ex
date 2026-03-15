defmodule AeroVision.Flight.StateVector do
  @moduledoc "Raw ADS-B state vector from OpenSky Network API."

  defstruct [
    :icao24,           # String - ICAO 24-bit transponder address (hex)
    :callsign,         # String | nil - 8-char callsign
    :origin_country,   # String
    :time_position,    # integer | nil - unix timestamp of last position
    :last_contact,     # integer - unix timestamp of last update
    :longitude,        # float | nil - WGS-84 decimal degrees
    :latitude,         # float | nil - WGS-84 decimal degrees
    :baro_altitude,    # float | nil - barometric altitude in meters
    :on_ground,        # boolean
    :velocity,         # float | nil - ground speed in m/s
    :true_track,       # float | nil - track angle in degrees (north=0°, clockwise)
    :vertical_rate,    # float | nil - m/s (positive=climbing)
    :geo_altitude,     # float | nil - geometric altitude in meters
    :squawk,           # String | nil
    :position_source   # integer - 0=ADS-B, 1=ASTERIX, 2=MLAT, 3=FLARM
  ]

  @type t :: %__MODULE__{}

  @doc "Parse a single state vector from OpenSky's array format."
  def from_array([icao24, callsign, origin_country, time_position, last_contact,
                  longitude, latitude, baro_altitude, on_ground, velocity,
                  true_track, vertical_rate, _sensors, geo_altitude, squawk,
                  _spi, position_source | _rest]) do
    %__MODULE__{
      icao24: icao24,
      callsign: callsign && String.trim(callsign),
      origin_country: origin_country,
      time_position: time_position,
      last_contact: last_contact,
      longitude: longitude,
      latitude: latitude,
      baro_altitude: baro_altitude,
      on_ground: on_ground,
      velocity: velocity,
      true_track: true_track,
      vertical_rate: vertical_rate,
      geo_altitude: geo_altitude,
      squawk: squawk,
      position_source: position_source
    }
  end

  def from_array(_), do: nil
end
