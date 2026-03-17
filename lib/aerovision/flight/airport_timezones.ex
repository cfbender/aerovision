defmodule AeroVision.Flight.AirportTimezones do
  @moduledoc """
  Static mapping of IATA airport codes to IANA timezone identifiers.
  Used to convert local airport times from Skylink API to UTC.
  Falls back to a configurable default (or Etc/UTC) for unknown airports.
  """

  @iata_to_tz %{
    # ── US Eastern ────────────────────────────────────
    "ATL" => "America/New_York",
    "BOS" => "America/New_York",
    "BWI" => "America/New_York",
    "CHS" => "America/New_York",
    "CLE" => "America/New_York",
    "CLT" => "America/New_York",
    "CMH" => "America/New_York",
    "CVG" => "America/New_York",
    "DCA" => "America/New_York",
    "DTW" => "America/New_York",
    "EWR" => "America/New_York",
    "FLL" => "America/New_York",
    "IAD" => "America/New_York",
    "IND" => "America/New_York",
    "JAX" => "America/New_York",
    "JFK" => "America/New_York",
    "LGA" => "America/New_York",
    "MCO" => "America/New_York",
    "MIA" => "America/New_York",
    "ORF" => "America/New_York",
    "PBI" => "America/New_York",
    "PHL" => "America/New_York",
    "PIT" => "America/New_York",
    "PVD" => "America/New_York",
    "RDU" => "America/New_York",
    "RIC" => "America/New_York",
    "RSW" => "America/New_York",
    "SAV" => "America/New_York",
    "SDF" => "America/New_York",
    "SRQ" => "America/New_York",
    "TPA" => "America/New_York",

    # ── US Central ────────────────────────────────────
    "AUS" => "America/Chicago",
    "BHM" => "America/Chicago",
    "BNA" => "America/Chicago",
    "DAL" => "America/Chicago",
    "DFW" => "America/Chicago",
    "DSM" => "America/Chicago",
    "HOU" => "America/Chicago",
    "IAH" => "America/Chicago",
    "MCI" => "America/Chicago",
    "MDW" => "America/Chicago",
    "MEM" => "America/Chicago",
    "MKE" => "America/Chicago",
    "MSN" => "America/Chicago",
    "MSP" => "America/Chicago",
    "MSY" => "America/Chicago",
    "OKC" => "America/Chicago",
    "OMA" => "America/Chicago",
    "ORD" => "America/Chicago",
    "SAT" => "America/Chicago",
    "STL" => "America/Chicago",
    "TUL" => "America/Chicago",

    # ── US Mountain ───────────────────────────────────
    "ABQ" => "America/Denver",
    "BOI" => "America/Denver",
    "COS" => "America/Denver",
    "DEN" => "America/Denver",
    "ELP" => "America/Denver",
    "PHX" => "America/Phoenix",
    "SLC" => "America/Denver",
    "TUS" => "America/Phoenix",

    # ── US Pacific ────────────────────────────────────
    "BUR" => "America/Los_Angeles",
    "GEG" => "America/Los_Angeles",
    "LAX" => "America/Los_Angeles",
    "LGB" => "America/Los_Angeles",
    "OAK" => "America/Los_Angeles",
    "ONT" => "America/Los_Angeles",
    "PDX" => "America/Los_Angeles",
    "SAN" => "America/Los_Angeles",
    "SEA" => "America/Los_Angeles",
    "SFO" => "America/Los_Angeles",
    "SJC" => "America/Los_Angeles",
    "SMF" => "America/Los_Angeles",
    "SNA" => "America/Los_Angeles",

    # ── US Alaska / Hawaii ────────────────────────────
    "ANC" => "America/Anchorage",
    "HNL" => "Pacific/Honolulu",
    "OGG" => "Pacific/Honolulu",

    # ── Canada ────────────────────────────────────────
    "YUL" => "America/Toronto",
    "YYZ" => "America/Toronto",
    "YOW" => "America/Toronto",
    "YVR" => "America/Vancouver",
    "YYC" => "America/Edmonton",
    "YEG" => "America/Edmonton",
    "YWG" => "America/Winnipeg",
    "YHZ" => "America/Halifax",

    # ── Europe ────────────────────────────────────────
    "AMS" => "Europe/Amsterdam",
    "BCN" => "Europe/Madrid",
    "CDG" => "Europe/Paris",
    "DUB" => "Europe/Dublin",
    "FCO" => "Europe/Rome",
    "FRA" => "Europe/Berlin",
    "LHR" => "Europe/London",
    "LGW" => "Europe/London",
    "MAD" => "Europe/Madrid",
    "MUC" => "Europe/Berlin",
    "ZRH" => "Europe/Zurich",

    # ── Asia / Pacific ────────────────────────────────
    "HND" => "Asia/Tokyo",
    "NRT" => "Asia/Tokyo",
    "ICN" => "Asia/Seoul",
    "PEK" => "Asia/Shanghai",
    "PVG" => "Asia/Shanghai",
    "SIN" => "Asia/Singapore",
    "SYD" => "Australia/Sydney",

    # ── Latin America / Caribbean ─────────────────────
    "CUN" => "America/Cancun",
    "GUA" => "America/Guatemala",
    "MEX" => "America/Mexico_City",
    "PTY" => "America/Panama",
    "SJU" => "America/Puerto_Rico",
    "GRU" => "America/Sao_Paulo"
  }

  @doc """
  Returns the IANA timezone for a given IATA airport code.
  Falls back to the provided default (or "Etc/UTC") if the airport is unknown.
  """
  def timezone_for(code, fallback \\ "Etc/UTC")

  def timezone_for(nil, fallback), do: fallback
  def timezone_for("", fallback), do: fallback

  def timezone_for(code, fallback) do
    Map.get(@iata_to_tz, String.upcase(code), fallback)
  end
end
