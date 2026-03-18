defmodule AeroVision.Flight.StateVector do
  @moduledoc "Raw ADS-B state vector from Skylink API."

  defstruct [
    # String - ICAO 24-bit transponder address (hex)
    :icao24,
    # String | nil - 8-char callsign
    :callsign,
    # String
    :origin_country,
    # integer | nil - unix timestamp of last position
    :time_position,
    # integer - unix timestamp of last update
    :last_contact,
    # float | nil - WGS-84 decimal degrees
    :longitude,
    # float | nil - WGS-84 decimal degrees
    :latitude,
    # float | nil - barometric altitude in feet
    :baro_altitude,
    # boolean
    :on_ground,
    # float | nil - ground speed in knots
    :velocity,
    # float | nil - track angle in degrees (north=0°, clockwise)
    :true_track,
    # float | nil - vertical rate in ft/min (positive=climbing)
    :vertical_rate,
    # float | nil - geometric altitude in meters
    :geo_altitude,
    # String | nil
    :squawk,
    # integer - 0=ADS-B, 1=ASTERIX, 2=MLAT, 3=FLARM
    :position_source,
    # integer | nil - aircraft category (0-20, see OpenSky docs)
    :category,
    # String | nil - aircraft type name from ADS-B (e.g., "Boeing 777-36N")
    :aircraft_type_name,
    # String | nil - aircraft registration / tail number (e.g., "N123DL")
    :registration
  ]

  @type t :: %__MODULE__{}

  @doc "Parse a single state vector from Skylink's map format."
  def from_skylink(%{"icao24" => icao24} = data) when is_binary(icao24) do
    %__MODULE__{
      icao24: icao24,
      callsign: data["callsign"] && String.trim(data["callsign"]),
      origin_country: nil,
      time_position: parse_iso8601_to_unix(data["first_seen"]),
      last_contact: parse_iso8601_to_unix(data["last_seen"]),
      longitude: data["longitude"],
      latitude: data["latitude"],
      baro_altitude: data["altitude"],
      on_ground: data["is_on_ground"] || false,
      velocity: data["ground_speed"],
      true_track: data["track"],
      vertical_rate: data["vertical_rate"],
      geo_altitude: nil,
      squawk: nil,
      position_source: nil,
      category: nil,
      aircraft_type_name: data["aircraft_type"],
      registration: data["registration"]
    }
  end

  def from_skylink(_), do: nil

  @doc "Parse a single state vector from OpenSky's array format, converting to imperial units."
  def from_opensky(arr) when is_list(arr) and length(arr) >= 17 do
    raw_alt = Enum.at(arr, 7)
    raw_vel = Enum.at(arr, 9)
    raw_vrate = Enum.at(arr, 11)

    %__MODULE__{
      icao24: Enum.at(arr, 0),
      callsign: trim_callsign(Enum.at(arr, 1)),
      origin_country: Enum.at(arr, 2),
      time_position: Enum.at(arr, 3),
      last_contact: Enum.at(arr, 4),
      longitude: Enum.at(arr, 5),
      latitude: Enum.at(arr, 6),
      # OpenSky returns meters — convert to feet
      baro_altitude: meters_to_feet(raw_alt),
      on_ground: Enum.at(arr, 8) || false,
      # OpenSky returns m/s — convert to knots
      velocity: ms_to_knots(raw_vel),
      true_track: Enum.at(arr, 10),
      # OpenSky returns m/s — convert to ft/min
      vertical_rate: ms_to_fpm(raw_vrate),
      geo_altitude: Enum.at(arr, 13),
      squawk: Enum.at(arr, 14),
      position_source: Enum.at(arr, 16),
      category: Enum.at(arr, 17),
      aircraft_type_name: nil,
      registration: nil
    }
  end

  def from_opensky(_), do: nil

  # Parses an ISO 8601 datetime string to a Unix timestamp integer.
  # Returns nil if the input is nil or unparseable.
  defp parse_iso8601_to_unix(nil), do: nil

  defp parse_iso8601_to_unix(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp trim_callsign(nil), do: nil

  defp trim_callsign(cs) when is_binary(cs) do
    trimmed = String.trim(cs)
    if trimmed == "", do: nil, else: trimmed
  end

  defp meters_to_feet(nil), do: nil
  defp meters_to_feet(m), do: m * 3.28084

  defp ms_to_knots(nil), do: nil
  defp ms_to_knots(ms), do: ms * 1.94384

  defp ms_to_fpm(nil), do: nil
  defp ms_to_fpm(ms), do: ms * 196.85
end
