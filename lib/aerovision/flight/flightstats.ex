defmodule AeroVision.Flight.FlightStats do
  @moduledoc """
  Scrapes FlightStats flight-tracker pages for flight enrichment data.

  Fetches the server-side rendered HTML from flightstats.com, extracts the
  embedded `__NEXT_DATA__` JSON (Next.js hydration state), and parses it
  into a `%FlightInfo{}` struct.

  This module is stateless — caching and rate-limiting are handled by the
  caller (typically `Skylink.FlightStatus` GenServer).
  """

  require Logger

  alias AeroVision.Flight.{FlightInfo, Airport, AirlineCodes}

  @base_url "https://www.flightstats.com/v2/flight-tracker"

  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0"

  # --- Public API ---

  @doc """
  Fetch enrichment data for an ADS-B callsign.

  Parses the callsign to determine the airline IATA code and flight number,
  fetches the FlightStats flight-tracker page, extracts the `__NEXT_DATA__`
  JSON, and returns a `%FlightInfo{}`.

  ## Examples

      iex> FlightStats.fetch("DAL1209")
      {:ok, %FlightInfo{ident: "DL1209", ...}}

      iex> FlightStats.fetch("N123AB")
      {:error, :unknown_callsign}
  """
  @spec fetch(String.t()) :: {:ok, FlightInfo.t()} | {:error, atom() | String.t()}
  def fetch(callsign) when is_binary(callsign) do
    with {:ok, {iata, flight_number}} <- AirlineCodes.parse_callsign(callsign),
         {:ok, html} <- fetch_page(iata, flight_number),
         {:ok, flight_data} <- extract_flight_data(html) do
      parse_flight(flight_data, iata)
    end
  end

  @doc """
  Fetch enrichment data given an IATA airline code and flight number directly.

  Useful when the callsign is already parsed or when testing.
  """
  @spec fetch_by_flight(String.t(), String.t()) ::
          {:ok, FlightInfo.t()} | {:error, atom() | String.t()}
  def fetch_by_flight(iata, flight_number) do
    with {:ok, html} <- fetch_page(iata, flight_number),
         {:ok, flight_data} <- extract_flight_data(html) do
      parse_flight(flight_data, iata)
    end
  end

  @doc """
  Parse a raw HTML string into flight data. Useful for testing with fixtures.
  """
  @spec parse_html(String.t()) :: {:ok, FlightInfo.t()} | {:error, atom() | String.t()}
  def parse_html(html) when is_binary(html) do
    with {:ok, flight_data} <- extract_flight_data(html) do
      # Derive IATA from the carrier in the data itself
      iata = get_in(flight_data, ["resultHeader", "carrier", "fs"]) || ""
      parse_flight(flight_data, iata)
    end
  end

  # --- HTTP ---

  defp fetch_page(iata, flight_number) do
    url = "#{@base_url}/#{URI.encode(iata)}/#{URI.encode(flight_number)}"

    headers = [
      {"user-agent", @user_agent},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.5"}
    ]

    case Req.get(url, headers: headers, redirect: true, max_redirects: 3, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # --- HTML/JSON Extraction ---

  # Use Floki to find the <script> tag containing __NEXT_DATA__ and extract the JSON.
  defp extract_flight_data(html) do
    with {:ok, document} <- Floki.parse_document(html),
         {:ok, json_str} <- find_next_data_script(document),
         {{:ok, data}, _} <- {Jason.decode(json_str), json_str},
         flight when not is_nil(flight) <-
           get_in(data, ["props", "initialState", "flightTracker", "flight"]) do
      {:ok, flight}
    else
      nil ->
        {:error, :no_flight_data}

      {{:error, %Jason.DecodeError{}}, json_str} ->
        IO.inspect(json_str,
          label: "Failed to decode JSON from __NEXT_DATA__",
          printable_limit: :infinity
        )

        {:error, :truncated_response}

      {:error, _} = error ->
        error

      other ->
        {:error, {:parse_error, other}}
    end
  end

  defp find_next_data_script(document) do
    scripts = Floki.find(document, "script")

    result =
      Enum.find_value(scripts, fn node ->
        text = script_raw_text(node)

        if String.contains?(text, "__NEXT_DATA__") do
          case Regex.run(~r/__NEXT_DATA__\s*=\s*/, text, return: :index) do
            [{start, len}] ->
              json_start = start + len
              extract_balanced_json(text, json_start)

            _ ->
              nil
          end
        end
      end)

    case result do
      nil -> {:error, :no_next_data}
      json -> {:ok, json}
    end
  end

  # Extract a balanced JSON object starting at the given byte offset.
  # Scans from the opening { and counts brace depth to find the matching }.
  defp extract_balanced_json(text, offset) do
    rest = binary_part(text, offset, byte_size(text) - offset)

    case find_closing_brace(rest, 0, 0, false) do
      {:ok, end_pos} ->
        binary_part(rest, 0, end_pos + 1)

      :error ->
        nil
    end
  end

  # Walk through the binary tracking brace depth and string-literal context.
  # Returns {:ok, byte_position} of the closing brace that balances the first
  # opening brace, or :error if the braces never balance.
  defp find_closing_brace(<<>>, _pos, _depth, _in_string), do: :error

  # Escaped character inside a string literal — skip it
  defp find_closing_brace(<<"\\", _, rest::binary>>, pos, depth, true) do
    find_closing_brace(rest, pos + 2, depth, true)
  end

  # Toggle string-literal context on unescaped double-quote
  defp find_closing_brace(<<"\"", rest::binary>>, pos, depth, in_string) do
    find_closing_brace(rest, pos + 1, depth, not in_string)
  end

  # Opening brace outside a string — increase depth
  defp find_closing_brace(<<"{", rest::binary>>, pos, depth, false) do
    find_closing_brace(rest, pos + 1, depth + 1, false)
  end

  # Closing brace at depth 1 — this is the matching brace for the outermost {
  defp find_closing_brace(<<"}", _rest::binary>>, pos, 1, false) do
    {:ok, pos}
  end

  # Closing brace at depth > 1 — decrease depth
  defp find_closing_brace(<<"}", rest::binary>>, pos, depth, false) when depth > 1 do
    find_closing_brace(rest, pos + 1, depth - 1, false)
  end

  # Any other byte — keep scanning
  defp find_closing_brace(<<_, rest::binary>>, pos, depth, in_string) do
    find_closing_brace(rest, pos + 1, depth, in_string)
  end

  # Extract the raw text content from a Floki script node.
  # Script tag children are raw text strings, not parsed HTML nodes.
  defp script_raw_text({_tag, _attrs, children}) do
    children
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp script_raw_text(_), do: ""

  # --- Flight Data Parsing ---

  defp parse_flight(flight, iata) do
    carrier = get_in(flight, ["resultHeader", "carrier"]) || %{}
    schedule = flight["schedule"] || %{}
    status_data = flight["status"] || %{}
    equipment = get_in(flight, ["additionalFlightInfo", "equipment"]) || %{}
    dep_airport = flight["departureAirport"]
    arr_airport = flight["arrivalAirport"]

    flight_number = get_in(flight, ["resultHeader", "flightNumber"]) || ""
    carrier_fs = carrier["fs"] || iata

    # Determine actual vs estimated times based on title fields
    {actual_dep, estimated_dep} = classify_departure_time(schedule)
    {_actual_arr, estimated_arr} = classify_arrival_time(schedule)

    info = %FlightInfo{
      ident: "#{carrier_fs}#{flight_number}",
      operator: AirlineCodes.iata_to_icao(carrier_fs),
      airline_name: carrier["name"],
      aircraft_type: equipment["iata"],
      aircraft_name: equipment["name"],
      origin: parse_airport(dep_airport),
      destination: parse_airport(arr_airport),
      departure_time: parse_utc_datetime(schedule["scheduledDepartureUTC"]),
      actual_departure_time: actual_dep,
      arrival_time: parse_utc_datetime(schedule["scheduledArrivalUTC"]),
      estimated_departure_time: estimated_dep,
      estimated_arrival_time: estimated_arr,
      status: normalize_status(status_data["status"]),
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    {:ok, info}
  end

  # If the "estimatedActualDepartureTitle" is "Actual", the time is the actual departure.
  # If "Estimated", it's an estimated departure (e.g., delayed).
  defp classify_departure_time(schedule) do
    utc = parse_utc_datetime(schedule["estimatedActualDepartureUTC"])

    case schedule["estimatedActualDepartureTitle"] do
      "Actual" -> {utc, nil}
      "Estimated" -> {nil, utc}
      _ -> {nil, nil}
    end
  end

  defp classify_arrival_time(schedule) do
    utc = parse_utc_datetime(schedule["estimatedActualArrivalUTC"])

    case schedule["estimatedActualArrivalTitle"] do
      "Actual" -> {utc, nil}
      "Estimated" -> {nil, utc}
      _ -> {nil, nil}
    end
  end

  defp parse_airport(nil), do: nil

  defp parse_airport(data) when is_map(data) do
    %Airport{
      icao: nil,
      iata: data["iata"],
      name: data["name"],
      city: data["city"]
    }
  end

  # Parse UTC ISO 8601 datetime strings like "2026-03-18T17:36:00.000Z"
  defp parse_utc_datetime(nil), do: nil
  defp parse_utc_datetime(""), do: nil

  defp parse_utc_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        # Try without Z suffix (some fields may be local times without offset)
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  # Normalize status strings to match what the rest of the app expects
  defp normalize_status(nil), do: nil
  defp normalize_status("Scheduled"), do: "Scheduled"
  defp normalize_status("Departed"), do: "En Route"
  defp normalize_status("In Air"), do: "En Route"
  defp normalize_status("Landed"), do: "Landed"
  defp normalize_status("Canceled"), do: "Cancelled"
  defp normalize_status("Cancelled"), do: "Cancelled"
  defp normalize_status("Diverted"), do: "Diverted"
  defp normalize_status(other), do: other
end
