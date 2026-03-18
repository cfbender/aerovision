defmodule AeroVision.Flight.Utils.AircraftCodes do
  @moduledoc """
  Aircraft type code abbreviation utilities.

  Converts full aircraft type names from various sources (Skylink, ADS-B feeds)
  into ICAO-style short codes for display.

  ## Examples

      iex> AeroVision.Flight.AircraftCodes.abbreviate("Boeing 737-800")
      "B738"

      iex> AeroVision.Flight.AircraftCodes.abbreviate("Airbus A321-200")
      "A321"

      iex> AeroVision.Flight.AircraftCodes.abbreviate("Embraer E175")
      "E175"

      iex> AeroVision.Flight.AircraftCodes.abbreviate(nil)
      nil

  """

  @doc """
  Abbreviate an aircraft type name to an ICAO-style short code.

  Returns `nil` if the input is `nil` or if no abbreviation pattern matches.
  """
  def abbreviate(nil), do: nil

  def abbreviate(name) when is_binary(name) do
    abbreviate_boeing(name) ||
      abbreviate_airbus(name) ||
      abbreviate_embraer(name) ||
      abbreviate_crj(name)
  end

  # Convert "BOEING B738" → "B738", "Boeing 737-800" → "B738", "Boeing 777" → "B777"
  defp abbreviate_boeing(name) do
    # ADS-B ICAO type code format: "BOEING B738", "BOEING B77W", "BOEING B789"
    case Regex.run(~r/Boeing\s+(B\w{3,4})\b/i, name) do
      [_, code] ->
        String.upcase(code)

      _ ->
        # Full name format: "Boeing 737-800" → "B738", "Boeing 777" → "B777"
        case Regex.run(~r/Boeing\s+(\d{3})(?:[- ](\d))?/i, name) do
          [_, model, variant_digit] -> "B#{String.slice(model, 0, 2)}#{variant_digit}"
          [_, model] -> "B#{model}"
          _ -> nil
        end
    end
  end

  # Convert "Airbus A321-200" → "A321", "A320" → "A320"
  defp abbreviate_airbus(name) do
    case Regex.run(~r/(A\d{3})/i, name) do
      [_, code] -> String.upcase(code)
      _ -> nil
    end
  end

  # Convert "Embraer E175" → "E175", "E190" → "E190"
  defp abbreviate_embraer(name) do
    case Regex.run(~r/(E\d{2,3})/i, name) do
      [_, code] -> String.upcase(code)
      _ -> nil
    end
  end

  # Convert "CRJ-700" → "CRJ7", "CRJ 9" → "CRJ9"
  defp abbreviate_crj(name) do
    case Regex.run(~r/CRJ[- ]?(\d)/i, name) do
      [_, digit] -> "CRJ#{digit}"
      _ -> nil
    end
  end
end
