defmodule AeroVision.Flight.Providers.Skylink.Api do
  @moduledoc """
  Flight data provider using the Skylink Flight Status API (via RapidAPI).

  This is the third-priority provider, called only when both FlightAware and
  FlightStats fail. Requires a RapidAPI key configured via
  `AeroVision.Config.Store` (`:skylink_api_key`).

  Monthly API call counts are tracked in Config.Store to stay within the free
  tier (~1,000 calls/month). The counter resets automatically on the first
  call of each new calendar month.
  """

  @behaviour AeroVision.Flight.FlightProvider

  alias AeroVision.Config.Store
  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightProvider
  alias AeroVision.Flight.Utils.AirportTimezones

  require Logger

  @impl FlightProvider
  def name, do: "Skylink"

  @base_url "https://skylink-api.p.rapidapi.com"
  @api_host "skylink-api.p.rapidapi.com"
  @monthly_call_cap 1_000

  # Months mapping for parsing Skylink's "11 Feb" style date strings
  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  # ─────────────────────────────────────────────────────────── public API ──

  @doc "Returns the number of Skylink API calls made this calendar month."
  @spec monthly_usage() :: non_neg_integer()
  def monthly_usage do
    ensure_current_month()
    Store.get(:skylink_monthly_count)
  end

  @doc """
  Fetch flight enrichment data from the Skylink API.

  Returns `{:error, :not_configured}` if no API key is set.
  Returns `{:error, :monthly_cap_reached}` if the monthly cap has been hit.
  """
  @impl FlightProvider
  def fetch(callsign) when is_binary(callsign) do
    cond do
      not credentials_configured?() ->
        {:error, :not_configured}

      monthly_usage() >= @monthly_call_cap ->
        {:error, :monthly_cap_reached}

      true ->
        case do_fetch(callsign) do
          {:ok, flight_info} ->
            increment_usage()
            {:ok, flight_info}

          error ->
            error
        end
    end
  end

  # ── HTTP ──────────────────────────────────────────────────────────────────

  defp do_fetch(callsign) do
    key = api_key()
    url = "#{@base_url}/flight_status/#{URI.encode(callsign)}"

    headers = [
      {"X-RapidAPI-Key", key},
      {"X-RapidAPI-Host", @api_host}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        case parse_flight(body) do
          {:ok, flight_info} ->
            {:ok, flight_info}

          :error ->
            {:error, :no_flight_data}
        end

      {:ok, %{status: 404}} ->
        {:error, {:http_status, 404}}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ── Monthly usage tracking ───────────────────────────────────────────────

  defp increment_usage do
    ensure_current_month()
    new_count = Store.get(:skylink_monthly_count) + 1
    Store.put(:skylink_monthly_count, new_count)
  end

  # Reset counter if the stored month key doesn't match the current month.
  defp ensure_current_month do
    current = month_key()

    if Store.get(:skylink_month_key) != current do
      Store.put(:skylink_month_key, current)
      Store.put(:skylink_monthly_count, 0)
    end
  end

  defp month_key do
    date = Date.utc_today()
    "#{date.year}-#{String.pad_leading(to_string(date.month), 2, "0")}"
  end

  # ── Parse helpers ─────────────────────────────────────────────────────────

  defp parse_flight(%{"flight_number" => _, "status" => status} = body) do
    dep_airport = parse_airport(body["departure"])
    arr_airport = parse_airport(body["arrival"])

    dep_tz = AirportTimezones.timezone_for(dep_airport && dep_airport.iata)
    arr_tz = AirportTimezones.timezone_for(arr_airport && arr_airport.iata)

    info =
      Map.put(
        %FlightInfo{
          ident: body["flight_number"],
          operator: nil,
          airline_name: body["airline"],
          aircraft_type: nil,
          origin: dep_airport,
          destination: arr_airport,
          departure_time:
            parse_datetime(
              get_in(body, ["departure", "scheduled_time"]),
              get_in(body, ["departure", "scheduled_date"]),
              dep_tz
            ),
          actual_departure_time:
            parse_datetime(
              get_in(body, ["departure", "actual_time"]),
              get_in(body, ["departure", "actual_date"]),
              dep_tz
            ),
          arrival_time:
            parse_datetime(
              get_in(body, ["arrival", "scheduled_time"]),
              get_in(body, ["arrival", "scheduled_date"]),
              arr_tz
            ),
          estimated_departure_time:
            parse_datetime(
              get_in(body, ["departure", "estimated_time"]),
              get_in(body, ["departure", "estimated_date"]),
              dep_tz
            ),
          estimated_arrival_time:
            parse_datetime(
              get_in(body, ["arrival", "estimated_time"]),
              get_in(body, ["arrival", "estimated_date"]),
              arr_tz
            ),
          cached_at: DateTime.utc_now()
        },
        :status,
        status
      )

    {:ok, info}
  end

  defp parse_flight(_), do: :error

  defp parse_airport(nil), do: nil

  defp parse_airport(data) when is_map(data) do
    {iata, city} = split_airport_field(data["airport"])

    %Airport{
      icao: nil,
      iata: iata,
      name: data["airport_full"],
      city: city
    }
  end

  # Split "TPA • Tampa" into {"TPA", "Tampa"}.
  # Handles both bullet (•) and middle dot (·) separators.
  defp split_airport_field(nil), do: {nil, nil}

  defp split_airport_field(str) when is_binary(str) do
    case String.split(str, ~r/\s*[•·]\s*/, parts: 2) do
      [code, city] -> {String.trim(code), String.trim(city)}
      [code] -> {String.trim(code), nil}
    end
  end

  # Combines a time string like "10:30" and date string like "11 Feb" into a
  # UTC DateTime. The timezone argument is an IANA timezone string for the
  # airport where the time was recorded (e.g. "America/New_York"). Year is
  # inferred as current year; if the resulting date is more than 7 days in the
  # past we assume next year (handles year-boundary flights). Returns nil on
  # any parse failure or nil/empty input.
  defp parse_datetime(nil, _date, _tz), do: nil
  defp parse_datetime("", _date, _tz), do: nil
  defp parse_datetime(_time, nil, _tz), do: nil
  defp parse_datetime(_time, "", _tz), do: nil

  defp parse_datetime(time_str, date_str, timezone) do
    with [hour_str, minute_str] <- String.split(time_str, ":"),
         {hour, ""} <- Integer.parse(hour_str),
         {minute, ""} <- Integer.parse(minute_str),
         true <- hour in 0..23 and minute in 0..59,
         [day_str, month_name] <- String.split(date_str, " "),
         {day, ""} <- Integer.parse(day_str),
         {:ok, month} <- Map.fetch(@months, month_name) do
      today = Date.utc_today()
      year = infer_year(today, day, month)

      case Date.new(year, month, day) do
        {:ok, date} ->
          time = Time.new!(hour, minute, 0)

          case DateTime.new(date, time, timezone) do
            {:ok, local_dt} ->
              case DateTime.shift_zone(local_dt, "Etc/UTC") do
                {:ok, utc_dt} -> utc_dt
                _ -> nil
              end

            _ ->
              case DateTime.new(date, time) do
                {:ok, dt} -> dt
                _ -> nil
              end
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp infer_year(today, day, month) do
    case Date.new(today.year, month, day) do
      {:ok, candidate} ->
        if Date.diff(today, candidate) > 7 do
          today.year + 1
        else
          today.year
        end

      {:error, _} ->
        today.year
    end
  end

  # ── Config ────────────────────────────────────────────────────────────────

  defp credentials_configured? do
    key = Store.get(:skylink_api_key)
    is_binary(key) and key != ""
  end

  defp api_key do
    Store.get(:skylink_api_key)
  end
end
