defmodule AeroVision.Flight.AirlineCodesTest do
  use ExUnit.Case, async: true

  alias AeroVision.Flight.AirlineCodes

  # ──────────────────────────────────────────────── icao_to_iata ──

  describe "icao_to_iata/1" do
    test "US major carriers" do
      assert AirlineCodes.icao_to_iata("AAL") == "AA"
      assert AirlineCodes.icao_to_iata("DAL") == "DL"
      assert AirlineCodes.icao_to_iata("UAL") == "UA"
      assert AirlineCodes.icao_to_iata("SWA") == "WN"
      assert AirlineCodes.icao_to_iata("JBU") == "B6"
      assert AirlineCodes.icao_to_iata("ASA") == "AS"
      assert AirlineCodes.icao_to_iata("HAL") == "HA"
      assert AirlineCodes.icao_to_iata("FFT") == "F9"
      assert AirlineCodes.icao_to_iata("NKS") == "NK"
    end

    test "US regional carriers" do
      assert AirlineCodes.icao_to_iata("SKW") == "OO"
      assert AirlineCodes.icao_to_iata("RPA") == "YX"
      assert AirlineCodes.icao_to_iata("ENY") == "MQ"
      assert AirlineCodes.icao_to_iata("PDT") == "PT"
      assert AirlineCodes.icao_to_iata("GJS") == "G7"
    end

    test "Canadian carriers" do
      assert AirlineCodes.icao_to_iata("ACA") == "AC"
      assert AirlineCodes.icao_to_iata("WJA") == "WS"
      assert AirlineCodes.icao_to_iata("TSC") == "TS"
    end

    test "European carriers" do
      assert AirlineCodes.icao_to_iata("BAW") == "BA"
      assert AirlineCodes.icao_to_iata("DLH") == "LH"
      assert AirlineCodes.icao_to_iata("AFR") == "AF"
      assert AirlineCodes.icao_to_iata("KLM") == "KL"
      assert AirlineCodes.icao_to_iata("EZY") == "U2"
      assert AirlineCodes.icao_to_iata("RYR") == "FR"
      assert AirlineCodes.icao_to_iata("SAS") == "SK"
      assert AirlineCodes.icao_to_iata("FIN") == "AY"
      assert AirlineCodes.icao_to_iata("SWR") == "LX"
      assert AirlineCodes.icao_to_iata("WZZ") == "W6"
    end

    test "Middle Eastern carriers" do
      assert AirlineCodes.icao_to_iata("UAE") == "EK"
      assert AirlineCodes.icao_to_iata("QTR") == "QR"
      assert AirlineCodes.icao_to_iata("ETD") == "EY"
      assert AirlineCodes.icao_to_iata("THY") == "TK"
      assert AirlineCodes.icao_to_iata("ELY") == "LY"
    end

    test "Asian carriers" do
      assert AirlineCodes.icao_to_iata("ANA") == "NH"
      assert AirlineCodes.icao_to_iata("JAL") == "JL"
      assert AirlineCodes.icao_to_iata("CPA") == "CX"
      assert AirlineCodes.icao_to_iata("SIA") == "SQ"
      assert AirlineCodes.icao_to_iata("KAL") == "KE"
      assert AirlineCodes.icao_to_iata("CCA") == "CA"
      assert AirlineCodes.icao_to_iata("IGO") == "6E"
    end

    test "Oceanian carriers" do
      assert AirlineCodes.icao_to_iata("QFA") == "QF"
      assert AirlineCodes.icao_to_iata("ANZ") == "NZ"
      assert AirlineCodes.icao_to_iata("VOZ") == "VA"
      assert AirlineCodes.icao_to_iata("JST") == "JQ"
    end

    test "Latin American carriers" do
      assert AirlineCodes.icao_to_iata("AVA") == "AV"
      assert AirlineCodes.icao_to_iata("CMP") == "CM"
      assert AirlineCodes.icao_to_iata("AMX") == "AM"
      assert AirlineCodes.icao_to_iata("GLO") == "G3"
    end

    test "cargo carriers" do
      assert AirlineCodes.icao_to_iata("FDX") == "FX"
      assert AirlineCodes.icao_to_iata("UPS") == "5X"
      assert AirlineCodes.icao_to_iata("GTI") == "GT"
      assert AirlineCodes.icao_to_iata("CLX") == "CV"
    end

    test "input is case-insensitive" do
      assert AirlineCodes.icao_to_iata("dal") == "DL"
      assert AirlineCodes.icao_to_iata("Dal") == "DL"
    end

    test "unknown code returns nil" do
      assert AirlineCodes.icao_to_iata("XXX") == nil
      assert AirlineCodes.icao_to_iata("ZZZ") == nil
      assert AirlineCodes.icao_to_iata("ABC") == nil
    end
  end

  # ──────────────────────────────────────────────── iata_to_icao ──

  describe "iata_to_icao/1" do
    test "US major carriers" do
      assert AirlineCodes.iata_to_icao("AA") == "AAL"
      assert AirlineCodes.iata_to_icao("DL") == "DAL"
      assert AirlineCodes.iata_to_icao("UA") == "UAL"
      assert AirlineCodes.iata_to_icao("WN") == "SWA"
      assert AirlineCodes.iata_to_icao("B6") == "JBU"
      assert AirlineCodes.iata_to_icao("AS") == "ASA"
    end

    test "European carriers" do
      assert AirlineCodes.iata_to_icao("BA") == "BAW"
      assert AirlineCodes.iata_to_icao("LH") == "DLH"
      assert AirlineCodes.iata_to_icao("AF") == "AFR"
      assert AirlineCodes.iata_to_icao("KL") == "KLM"
      assert AirlineCodes.iata_to_icao("FR") == "RYR"
      assert AirlineCodes.iata_to_icao("U2") == "EZY"
    end

    test "Middle Eastern carriers" do
      assert AirlineCodes.iata_to_icao("EK") == "UAE"
      assert AirlineCodes.iata_to_icao("QR") == "QTR"
      assert AirlineCodes.iata_to_icao("TK") == "THY"
    end

    test "Asian carriers" do
      assert AirlineCodes.iata_to_icao("NH") == "ANA"
      assert AirlineCodes.iata_to_icao("JL") == "JAL"
      assert AirlineCodes.iata_to_icao("SQ") == "SIA"
      assert AirlineCodes.iata_to_icao("CX") == "CPA"
    end

    test "cargo carriers" do
      assert AirlineCodes.iata_to_icao("FX") == "FDX"
      assert AirlineCodes.iata_to_icao("5X") == "UPS"
    end

    test "input is case-insensitive" do
      assert AirlineCodes.iata_to_icao("dl") == "DAL"
      assert AirlineCodes.iata_to_icao("Dl") == "DAL"
    end

    test "unknown code returns nil" do
      assert AirlineCodes.iata_to_icao("ZZ") == nil
      assert AirlineCodes.iata_to_icao("XX") == nil
      assert AirlineCodes.iata_to_icao("99") == nil
    end
  end

  # ──────────────────────────────────────────────── parse_callsign ──

  describe "parse_callsign/1" do
    test "standard 3-letter ICAO prefix, numeric flight number" do
      assert AirlineCodes.parse_callsign("DAL1209") == {:ok, {"DL", "1209"}}
      assert AirlineCodes.parse_callsign("AAL100") == {:ok, {"AA", "100"}}
      assert AirlineCodes.parse_callsign("UAL231") == {:ok, {"UA", "231"}}
      assert AirlineCodes.parse_callsign("SWA2501") == {:ok, {"WN", "2501"}}
    end

    test "European carriers with 3-letter ICAO prefix" do
      assert AirlineCodes.parse_callsign("DLH400") == {:ok, {"LH", "400"}}
      assert AirlineCodes.parse_callsign("BAW178") == {:ok, {"BA", "178"}}
      assert AirlineCodes.parse_callsign("RYR1234") == {:ok, {"FR", "1234"}}
      assert AirlineCodes.parse_callsign("AFR084") == {:ok, {"AF", "084"}}
    end

    test "Middle Eastern carriers with 3-letter ICAO prefix" do
      assert AirlineCodes.parse_callsign("UAE215") == {:ok, {"EK", "215"}}
      assert AirlineCodes.parse_callsign("QTR8") == {:ok, {"QR", "8"}}
    end

    test "alphanumeric suffix in flight number" do
      assert AirlineCodes.parse_callsign("THY5KM") == {:ok, {"TK", "5KM"}}
      assert AirlineCodes.parse_callsign("DAL12B") == {:ok, {"DL", "12B"}}
      assert AirlineCodes.parse_callsign("UAL7X") == {:ok, {"UA", "7X"}}
    end

    test "short (single-digit) flight number" do
      assert AirlineCodes.parse_callsign("BAW5") == {:ok, {"BA", "5"}}
      assert AirlineCodes.parse_callsign("QFA1") == {:ok, {"QF", "1"}}
    end

    test "large flight number" do
      assert AirlineCodes.parse_callsign("SWA9999") == {:ok, {"WN", "9999"}}
      assert AirlineCodes.parse_callsign("SKW5462") == {:ok, {"OO", "5462"}}
    end

    test "input is upcased before matching" do
      assert AirlineCodes.parse_callsign("dal1209") == {:ok, {"DL", "1209"}}
      assert AirlineCodes.parse_callsign("Dal1209") == {:ok, {"DL", "1209"}}
      assert AirlineCodes.parse_callsign("dlh400") == {:ok, {"LH", "400"}}
    end

    test "leading/trailing whitespace is stripped" do
      assert AirlineCodes.parse_callsign("  DAL1209  ") == {:ok, {"DL", "1209"}}
      assert AirlineCodes.parse_callsign("DAL1209  ") == {:ok, {"DL", "1209"}}
      assert AirlineCodes.parse_callsign("  DAL1209") == {:ok, {"DL", "1209"}}
    end

    test "GA tail numbers return :unknown_callsign" do
      # N-number format — not an airline callsign
      assert AirlineCodes.parse_callsign("N123AB") == {:error, :unknown_callsign}
      assert AirlineCodes.parse_callsign("N12345") == {:error, :unknown_callsign}
      assert AirlineCodes.parse_callsign("G-BOAC") == {:error, :unknown_callsign}
    end

    test "unknown ICAO prefix returns :unknown_callsign" do
      assert AirlineCodes.parse_callsign("XYZ1234") == {:error, :unknown_callsign}
      assert AirlineCodes.parse_callsign("ZZZ999") == {:error, :unknown_callsign}
    end

    test "no numeric portion returns :unknown_callsign" do
      assert AirlineCodes.parse_callsign("DAL") == {:error, :unknown_callsign}
      assert AirlineCodes.parse_callsign("DALAB") == {:error, :unknown_callsign}
    end

    test "empty string returns :unknown_callsign" do
      assert AirlineCodes.parse_callsign("") == {:error, :unknown_callsign}
    end

    test "whitespace-only string returns :unknown_callsign" do
      assert AirlineCodes.parse_callsign("   ") == {:error, :unknown_callsign}
    end

    test "cargo carrier callsigns" do
      assert AirlineCodes.parse_callsign("FDX1234") == {:ok, {"FX", "1234"}}
      assert AirlineCodes.parse_callsign("UPS765") == {:ok, {"5X", "765"}}
    end

    test "Asian carrier callsigns" do
      assert AirlineCodes.parse_callsign("ANA7") == {:ok, {"NH", "7"}}
      assert AirlineCodes.parse_callsign("JAL516") == {:ok, {"JL", "516"}}
      assert AirlineCodes.parse_callsign("SIA231") == {:ok, {"SQ", "231"}}
    end
  end
end
