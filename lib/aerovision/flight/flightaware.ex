defmodule AeroVision.Flight.FlightAware do
  @moduledoc """
  Scrapes FlightAware flight-tracker pages for flight enrichment data.

  Fetches the server-side rendered HTML from flightaware.com, extracts the
  embedded `trackpollBootstrap` JSON from an inline `<script>` tag, and parses
  it into a `%FlightInfo{}` struct.

  FlightAware uses ICAO callsigns directly (e.g., `DAL1209`, `SWA3137`), so no
  IATA conversion is needed.

  This module is stateless — caching and rate-limiting are handled by the
  caller (typically `Skylink.FlightStatus` GenServer).
  """

  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightInfo

  require Logger

  @base_url "https://www.flightaware.com/live/flight"

  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0"

  # --- Public API ---

  @doc """
  Fetch enrichment data for an ADS-B callsign.

  Uses the ICAO callsign directly (e.g., `DAL1209`, `SWA3137`) to construct
  the FlightAware URL, fetches the page, extracts the `trackpollBootstrap`
  JSON, and returns a `%FlightInfo{}`.

  ## Examples

      iex> FlightAware.fetch("DAL1209")
      {:ok, %FlightInfo{ident: "DAL1209", ...}}

      iex> FlightAware.fetch("N123AB")
      {:error, :no_flight_data}
  """
  @spec fetch(String.t()) :: {:ok, FlightInfo.t()} | {:error, atom() | tuple()}
  def fetch(callsign) when is_binary(callsign) do
    normalized = callsign |> String.trim() |> String.upcase()

    with {:ok, html} <- fetch_page(normalized),
         {:ok, flight} <- extract_flight_data(html) do
      parse_flight(flight)
    end
  end

  @doc """
  Parse a raw HTML string into flight data. Useful for testing with fixtures.
  """
  @spec parse_html(String.t()) :: {:ok, FlightInfo.t()} | {:error, atom() | tuple()}
  def parse_html(html) when is_binary(html) do
    with {:ok, flight} <- extract_flight_data(html) do
      parse_flight(flight)
    end
  end

  # --- HTTP ---

  defp fetch_page(callsign) do
    url = "#{@base_url}/#{URI.encode(callsign)}"

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

  # Use Floki to find the <script> tag containing trackpollBootstrap and extract
  # the JSON using a balanced brace scanner.
  defp extract_flight_data(html) do
    with {:ok, document} <- Floki.parse_document(html),
         {:ok, json_str} <- find_bootstrap_script(document),
         {:ok, data} <- Jason.decode(json_str),
         {:ok, flight} <- extract_first_flight(data) do
      {:ok, flight}
    else
      {:error, _} = error -> error
      other -> {:error, {:parse_error, other}}
    end
  end

  defp find_bootstrap_script(document) do
    scripts = Floki.find(document, "script")

    result =
      Enum.find_value(scripts, fn node ->
        text = script_raw_text(node)

        if String.contains?(text, "trackpollBootstrap") do
          case Regex.run(~r/var trackpollBootstrap\s*=\s*/, text, return: :index) do
            [{start, len}] ->
              json_start = start + len
              extract_balanced_json(text, json_start)

            _ ->
              nil
          end
        end
      end)

    case result do
      nil -> {:error, :no_bootstrap_data}
      json -> {:ok, json}
    end
  end

  defp extract_first_flight(%{"flights" => flights}) when is_map(flights) and map_size(flights) > 0 do
    {_key, flight} = Enum.at(flights, 0)
    {:ok, flight}
  end

  defp extract_first_flight(_), do: {:error, :no_flight_data}

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

  defp parse_flight(flight) do
    airline = flight["airline"] || %{}
    aircraft = flight["aircraft"] || %{}

    info = %FlightInfo{
      ident: flight["ident"],
      operator: airline["icao"],
      airline_name: airline["shortName"],
      aircraft_type: aircraft["type"],
      aircraft_name: aircraft["friendlyType"],
      origin: parse_airport(flight["origin"]),
      destination: parse_airport(flight["destination"]),
      departure_time: from_unix(get_in(flight, ["gateDepartureTimes", "scheduled"])),
      actual_departure_time: from_unix(get_in(flight, ["gateDepartureTimes", "actual"])),
      estimated_departure_time: from_unix(get_in(flight, ["gateDepartureTimes", "estimated"])),
      arrival_time: from_unix(get_in(flight, ["gateArrivalTimes", "scheduled"])),
      estimated_arrival_time: from_unix(get_in(flight, ["gateArrivalTimes", "estimated"])),
      status: normalize_status(flight),
      progress_pct: compute_progress(flight),
      cached_at: DateTime.utc_now()
    }

    Logger.debug("FlightAware parsed flight: #{inspect(info.ident)} status=#{inspect(info.status)}")

    {:ok, info}
  end

  defp parse_airport(nil), do: nil

  defp parse_airport(data) when is_map(data) do
    %Airport{
      icao: data["icao"],
      iata: data["iata"],
      name: data["friendlyName"],
      city: data["friendlyLocation"]
    }
  end

  defp from_unix(nil), do: nil
  defp from_unix(epoch) when is_integer(epoch), do: DateTime.from_unix!(epoch)

  defp compute_progress(flight) do
    elapsed = get_in(flight, ["distance", "elapsed"])
    remaining = get_in(flight, ["distance", "remaining"])

    cond do
      is_nil(elapsed) or is_nil(remaining) -> nil
      elapsed + remaining == 0 -> nil
      true -> elapsed / (elapsed + remaining)
    end
  end

  # Normalize FlightAware status fields into the canonical app status strings.
  # Check cancelled/diverted flags first before examining flightStatus string.
  defp normalize_status(%{"cancelled" => true}), do: "Cancelled"
  defp normalize_status(%{"diverted" => true}), do: "Diverted"
  defp normalize_status(%{"flightStatus" => "arrived"}), do: "Landed"

  defp normalize_status(%{"flightStatus" => status}) when is_binary(status) and status != "" do
    "En Route"
  end

  defp normalize_status(_), do: "Scheduled"
end
