defmodule AeroVision.Flight.AirlineCodes do
  @moduledoc """
  Bidirectional ICAO ↔ IATA airline code lookup and ADS-B callsign parser.

  Covers ~100 airlines across US majors/regionals, Canadian, European, Middle
  Eastern, Asian, Oceanian, Latin American, and cargo carriers.

  ## Examples

      iex> AeroVision.Flight.AirlineCodes.icao_to_iata("DAL")
      "DL"

      iex> AeroVision.Flight.AirlineCodes.iata_to_icao("LH")
      "DLH"

      iex> AeroVision.Flight.AirlineCodes.parse_callsign("DAL1209")
      {:ok, {"DL", "1209"}}

      iex> AeroVision.Flight.AirlineCodes.parse_callsign("THY5KM")
      {:ok, {"TK", "5KM"}}

      iex> AeroVision.Flight.AirlineCodes.parse_callsign("N123AB")
      {:error, :unknown_callsign}

  """

  # ICAO (3-letter) → IATA (2-letter) mapping
  # Format: {"ICAO" => "IATA"}
  @icao_to_iata %{
    # ── US Majors ──────────────────────────────────────────────────────────────
    "AAL" => "AA",
    # American Airlines
    "DAL" => "DL",
    # Delta Air Lines
    "UAL" => "UA",
    # United Airlines
    "SWA" => "WN",
    # Southwest Airlines
    "JBU" => "B6",
    # JetBlue Airways
    "ASA" => "AS",
    # Alaska Airlines
    "HAL" => "HA",
    # Hawaiian Airlines
    "FFT" => "F9",
    # Frontier Airlines
    "NKS" => "NK",
    # Spirit Airlines
    "SPR" => "NK",
    # Spirit Airlines (alternate ICAO — SPR was used historically)

    # ── US Regionals ───────────────────────────────────────────────────────────
    "SKW" => "OO",
    # SkyWest Airlines
    "RPA" => "YX",
    # Republic Airways
    "ENY" => "MQ",
    # Envoy Air (American Eagle)
    "ASH" => "QX",
    # Air Wisconsin (operated as United Express)
    "JIA" => "OH",
    # PSA Airlines
    "PDT" => "PT",
    # Piedmont Airlines
    "GJS" => "G7",
    # GoJet Airlines
    "EJA" => "XO",
    # NetJets (fractional — XO is the IATA; EJA is the ICAO callsign prefix)

    # ── Canadian ───────────────────────────────────────────────────────────────
    "ACA" => "AC",
    # Air Canada
    "WJA" => "WS",
    # WestJet
    "TSC" => "TS",
    # Air Transat

    # ── European ───────────────────────────────────────────────────────────────
    "BAW" => "BA",
    # British Airways
    "DLH" => "LH",
    # Lufthansa
    "AFR" => "AF",
    # Air France
    "KLM" => "KL",
    # KLM Royal Dutch Airlines
    "EZY" => "U2",
    # easyJet
    "RYR" => "FR",
    # Ryanair
    "VLG" => "VY",
    # Vueling Airlines
    "IBE" => "IB",
    # Iberia
    "SAS" => "SK",
    # Scandinavian Airlines
    "FIN" => "AY",
    # Finnair
    "AUA" => "OS",
    # Austrian Airlines
    "SWR" => "LX",
    # Swiss International Air Lines
    "TAP" => "TP",
    # TAP Air Portugal
    "BEL" => "SN",
    # Brussels Airlines
    "LOT" => "LO",
    # LOT Polish Airlines
    "AZA" => "AZ",
    # ITA Airways (formerly Alitalia)
    "CSA" => "OK",
    # Czech Airlines
    "EIN" => "EI",
    # Aer Lingus
    "ICE" => "FI",
    # Icelandair
    "NAX" => "DY",
    # Norwegian Air Shuttle
    "EWG" => "EW",
    # Eurowings
    "TUI" => "BY",
    # TUI Airways
    "WZZ" => "W6",
    # Wizz Air
    "EJU" => "EC",
    # easyJet Europe

    # ── Middle Eastern ─────────────────────────────────────────────────────────
    "UAE" => "EK",
    # Emirates
    "QTR" => "QR",
    # Qatar Airways
    "ETD" => "EY",
    # Etihad Airways
    "THY" => "TK",
    # Turkish Airlines
    "SVA" => "SV",
    # Saudia
    "MEA" => "ME",
    # Middle East Airlines
    "RJA" => "RJ",
    # Royal Jordanian
    "GFA" => "GF",
    # Gulf Air
    "KAC" => "KU",
    # Kuwait Airways
    "OMA" => "WY",
    # Oman Air
    "ELY" => "LY",
    # El Al Israel Airlines

    # ── Asian ──────────────────────────────────────────────────────────────────
    "ANA" => "NH",
    # All Nippon Airways
    "JAL" => "JL",
    # Japan Airlines
    "CPA" => "CX",
    # Cathay Pacific
    "SIA" => "SQ",
    # Singapore Airlines
    "KAL" => "KE",
    # Korean Air
    "AAR" => "OZ",
    # Asiana Airlines
    "CCA" => "CA",
    # Air China
    "CES" => "MU",
    # China Eastern Airlines
    "CSN" => "CZ",
    # China Southern Airlines
    "EVA" => "BR",
    # EVA Air
    "CAL" => "CI",
    # China Airlines
    "THA" => "TG",
    # Thai Airways
    "VNA" => "VN",
    # Vietnam Airlines
    "MAS" => "MH",
    # Malaysia Airlines
    "GIA" => "GA",
    # Garuda Indonesia
    "PAL" => "PR",
    # Philippine Airlines
    "AIC" => "AI",
    # Air India
    "IGO" => "6E",
    # IndiGo

    # ── Oceanian ───────────────────────────────────────────────────────────────
    "QFA" => "QF",
    # Qantas
    "ANZ" => "NZ",
    # Air New Zealand
    "VOZ" => "VA",
    # Virgin Australia
    "JST" => "JQ",
    # Jetstar Airways

    # ── Latin American ─────────────────────────────────────────────────────────
    "TAM" => "JJ",
    # LATAM Brasil (formerly TAM)
    "GLO" => "G3",
    # Gol Linhas Aéreas
    "AVA" => "AV",
    # Avianca
    "CMP" => "CM",
    # Copa Airlines
    "LAN" => "LA",
    # LATAM Airlines (formerly LAN)
    "AMX" => "AM",
    # Aeroméxico
    "AEA" => "UX",
    # Air Europa

    # ── Cargo ──────────────────────────────────────────────────────────────────
    "FDX" => "FX",
    # FedEx Express
    "UPS" => "5X",
    # UPS Airlines
    "GTI" => "GT",
    # Atlas Air
    "CLX" => "CV"
    # Cargolux
  }

  # Derive the reverse map at compile time. Where two ICAO codes map to the
  # same IATA code (e.g. SPR/NK and NKS/NK) the last one wins; use the
  # canonical entry (NKS) which appears later in the literal above.
  @iata_to_icao Map.new(@icao_to_iata, fn {icao, iata} -> {iata, icao} end)

  @doc """
  Convert an ICAO airline code to its IATA equivalent.

  Returns `nil` if the code is not in the known mapping.

  ## Examples

      iex> AeroVision.Flight.AirlineCodes.icao_to_iata("DAL")
      "DL"

      iex> AeroVision.Flight.AirlineCodes.icao_to_iata("XXX")
      nil

  """
  @spec icao_to_iata(String.t()) :: String.t() | nil
  def icao_to_iata(icao_code) when is_binary(icao_code) do
    Map.get(@icao_to_iata, String.upcase(icao_code))
  end

  @doc """
  Convert an IATA airline code to its ICAO equivalent.

  Returns `nil` if the code is not in the known mapping.

  ## Examples

      iex> AeroVision.Flight.AirlineCodes.iata_to_icao("LH")
      "DLH"

      iex> AeroVision.Flight.AirlineCodes.iata_to_icao("ZZ")
      nil

  """
  @spec iata_to_icao(String.t()) :: String.t() | nil
  def iata_to_icao(iata_code) when is_binary(iata_code) do
    Map.get(@iata_to_icao, String.upcase(iata_code))
  end

  @doc """
  Parse an ADS-B callsign into `{iata_airline_code, flight_number}`.

  The callsign is normalised (whitespace stripped, upcased) before matching.
  A 3-letter ICAO prefix is tried first; if that fails a 2-letter prefix is
  tried. The flight-number portion is returned as-is and may contain
  alphanumeric characters (e.g. `"5KM"`).

  Returns `{:ok, {iata, flight_number}}` on success, or
  `{:error, :unknown_callsign}` when no airline prefix can be resolved.

  ## Examples

      iex> AeroVision.Flight.AirlineCodes.parse_callsign("DAL1209")
      {:ok, {"DL", "1209"}}

      iex> AeroVision.Flight.AirlineCodes.parse_callsign("THY5KM")
      {:ok, {"TK", "5KM"}}

      iex> AeroVision.Flight.AirlineCodes.parse_callsign("N123AB")
      {:error, :unknown_callsign}

  """
  @spec parse_callsign(String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, :unknown_callsign}
  def parse_callsign(callsign) when is_binary(callsign) do
    normalised = callsign |> String.trim() |> String.upcase()
    try_3_letter(normalised) || try_2_letter(normalised) || {:error, :unknown_callsign}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Try matching a leading 3-letter ICAO prefix followed by a digit and
  # optional alphanumeric characters.
  defp try_3_letter(callsign) do
    case Regex.run(~r/^([A-Z]{3})(\d[\dA-Z]*)$/, callsign) do
      [_, prefix, number] ->
        case Map.get(@icao_to_iata, prefix) do
          nil -> nil
          iata -> {:ok, {iata, number}}
        end

      _ ->
        nil
    end
  end

  # Fall back to a 2-letter IATA prefix (some carriers broadcast their IATA
  # code directly in the callsign field).
  defp try_2_letter(callsign) do
    case Regex.run(~r/^([A-Z]{2})(\d[\dA-Z]*)$/, callsign) do
      [_, prefix, number] ->
        case Map.get(@iata_to_icao, prefix) do
          nil -> nil
          # We have a valid IATA prefix — return it directly
          _icao -> {:ok, {prefix, number}}
        end

      _ ->
        nil
    end
  end
end
