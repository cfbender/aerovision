defmodule AeroVision.Flight.Skylink.FlightStatus do
  @moduledoc """
  Flight enrichment client with FlightAware as primary source, FlightStats as
  secondary, and Skylink Flight Status API as final fallback.

  For each callsign, enrichment is attempted in order:

  1. **FlightAware** (`AeroVision.Flight.FlightAware`) — preferred because it
     provides ICAO aircraft type codes instead of IATA.
  2. **FlightStats** (`AeroVision.Flight.FlightStats`) — scrapes flightstats.com
     when FlightAware fails; no API key required and no monthly counter increment.
  3. **Skylink API** — called only when both free sources fail, credentials are
     configured, and the monthly cap has not been reached.

  Fetched data (origin/destination airports, airline name, departure/arrival
  times, flight status) is cached in ETS for 24 hours and persisted to CubDB
  so it survives reboots.

  Incoming enrichment requests are queued and processed at a max rate of
  1 request per second to respect API rate limits.

  Broadcasts `{:flight_enriched, callsign, %FlightInfo{}}` on PubSub topic
  "flights" when enrichment completes.

  Monthly Skylink API call counts are tracked in CubDB to help stay within
  the free tier (~1,000 calls/month).
  """

  use GenServer
  require Logger

  alias AeroVision.Config.Store
  alias AeroVision.Flight.FlightInfo
  alias AeroVision.Flight.FlightAware
  alias AeroVision.Flight.FlightStats
  alias AeroVision.Flight.Airport
  alias AeroVision.Flight.AirportTimezones
  alias AeroVision.TimeSync

  @pubsub AeroVision.PubSub
  @topic "flights"

  @cache_table :aerovision_skylink_cache
  @cache_ttl_sec 86_400
  @refresh_ttl_sec 1_800
  @rate_limit_ms 1_000
  @persist_table :aerovision_skylink_persist
  @monthly_call_cap 1_000
  # Buffer after scheduled arrival before considering cache stale (30 minutes)
  @arrival_buffer_sec 1_800

  @base_url "https://skylink-api.p.rapidapi.com"
  @api_host "skylink-api.p.rapidapi.com"

  # Bump this when cached data must be invalidated on next boot
  # (e.g. after fixing time-zone conversion bugs that produced bad timestamps).
  @cache_version 2

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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request enrichment for a callsign. Returns immediately.
  Result will be broadcast as `{:flight_enriched, callsign, %FlightInfo{}}`.
  """
  def enrich(callsign) when is_binary(callsign) do
    GenServer.cast(__MODULE__, {:enrich, callsign})
    :ok
  end

  @doc "Returns the number of Skylink API calls made this calendar month."
  def monthly_usage do
    GenServer.call(__MODULE__, :monthly_usage)
  end

  @doc "Clears all cached flight enrichment data from ETS and CubDB."
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  @doc "Synchronously look up a cached %FlightInfo{} by callsign, or nil."
  def get_cached(callsign) when is_binary(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, %FlightInfo{} = flight_info, cached_at}]
      when now - cached_at < @cache_ttl_sec ->
        if flight_arrived?(flight_info, now), do: nil, else: flight_info

      _ ->
        nil
    end
  end

  @doc """
  Returns true if a callsign's cached enrichment data exists but is older
  than the refresh TTL. Used by the Tracker to decide when tracked flights
  need re-enrichment for updated ETAs and status.
  """
  def needs_refresh?(callsign) when is_binary(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, %FlightInfo{}, cached_at}]
      when now - cached_at >= @refresh_ttl_sec and now - cached_at < @cache_ttl_sec ->
        true

      _ ->
        false
    end
  end

  @doc """
  Force re-enrichment of a callsign by clearing its ETS cache entry and
  re-queuing it. Used to refresh tracked flights with updated ETAs and status.

  Unlike `enrich/1`, this bypasses the cache check so already-cached callsigns
  can be re-fetched. The CubDB entry is preserved as crash-recovery fallback.
  """
  def re_enrich(callsign) when is_binary(callsign) do
    GenServer.cast(__MODULE__, {:re_enrich, callsign})
    :ok
  end

  # Check if a callsign has been negatively cached (enrichment permanently failed).
  # Uses the same ETS table but stores :not_found as the value instead of %FlightInfo{}.
  defp negatively_cached?(callsign) do
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, callsign) do
      [{^callsign, :not_found, cached_at}] when now - cached_at < @cache_ttl_sec -> true
      _ -> false
    end
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(opts) do
    # Create the ETS cache table if it does not already exist; clear it if it
    # does (e.g. after a supervised restart, so stale entries don't linger).
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    else
      :ets.delete_all_objects(@cache_table)
    end

    data_dir =
      Keyword.get(opts, :data_dir) ||
        case Application.get_env(:aerovision, :target, :host) do
          target when target in [:host, :test] ->
            Path.join(System.user_home!(), ".aerovision/skylink_cache")

          _ ->
            "/data/aerovision/skylink_cache"
        end

    File.mkdir_p!(data_dir)

    # Use a named CubDB only when no custom data_dir was provided (i.e. normal
    # startup). In tests, each test passes its own data_dir and we must NOT
    # share the named table or subsequent start_supervised! calls would get the
    # old process back via :already_started.
    db_opts =
      if Keyword.has_key?(opts, :data_dir) do
        [data_dir: data_dir]
      else
        [data_dir: data_dir, name: @persist_table]
      end

    db = AeroVision.DB.open(db_opts)

    # Load valid cache entries into ETS and purge expired ones from CubDB
    now = System.system_time(:second)

    CubDB.select(db)
    |> Enum.each(fn
      {key, {:not_found, cached_at}} when is_binary(key) ->
        if now - cached_at < @cache_ttl_sec do
          :ets.insert(@cache_table, {key, :not_found, cached_at})
        else
          CubDB.delete(db, key)
        end

      {key, {flight_info, cached_at}} when is_binary(key) ->
        if now - cached_at < @cache_ttl_sec do
          :ets.insert(@cache_table, {key, flight_info, cached_at})
        else
          CubDB.delete(db, key)
        end

      _ ->
        :ok
    end)

    # Check cache version — if stale, wipe enrichment data so incorrectly-stored
    # entries (e.g. local times stored as UTC before zoneinfo fix) don't linger.
    stored_version = CubDB.get(db, :cache_version, 0)

    if stored_version < @cache_version do
      Logger.info(
        "[Skylink.FlightStatus] Cache version #{stored_version} < #{@cache_version} — clearing stale enrichment data"
      )

      :ets.delete_all_objects(@cache_table)

      # Clear only string (callsign) keys; preserve system keys like {:calls, month} and :cache_version
      string_keys =
        CubDB.select(db)
        |> Enum.filter(fn {key, _} -> is_binary(key) end)
        |> Enum.map(fn {key, _} -> key end)

      if string_keys != [], do: CubDB.delete_multi(db, string_keys)
      CubDB.put(db, :cache_version, @cache_version)
    end

    # Read monthly call count
    month_key = month_key()
    call_count = CubDB.get(db, {:calls, month_key}, 0)

    state = %{
      queue: MapSet.new(),
      timer: nil,
      db: db,
      call_count: call_count,
      month_key: month_key
    }

    timer = schedule_tick()
    schedule_prune()
    {:ok, %{state | timer: timer}}
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    # Clear ETS cache
    :ets.delete_all_objects(@cache_table)

    # Clear callsign-keyed entries from CubDB (preserve monthly call counters)
    # Collect all string keys, then delete in one batch operation for better performance
    keys_to_delete =
      CubDB.select(state.db)
      |> Enum.filter(fn
        {key, _} when is_binary(key) -> true
        _ -> false
      end)
      |> Enum.map(fn {key, _} -> key end)

    if keys_to_delete != [] do
      CubDB.delete_multi(state.db, keys_to_delete)
    end

    Logger.info("[Skylink.FlightStatus] Cache purged")
    {:reply, :ok, %{state | queue: MapSet.new()}}
  end

  @impl true
  def handle_call(:monthly_usage, _from, state) do
    {:reply, state.call_count, state}
  end

  @impl true
  def handle_cast({:enrich, callsign}, state) do
    # Skip if already cached (positively or negatively) with a valid TTL
    if get_cached(callsign) || negatively_cached?(callsign) do
      {:noreply, state}
    else
      {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
    end
  end

  @impl true
  def handle_cast({:re_enrich, callsign}, state) do
    # Delete the ETS entry so the regular enrich gate passes through.
    # CubDB entry is preserved as crash-recovery fallback.
    :ets.delete(@cache_table, callsign)
    # Now enqueue via the normal path — get_cached will return nil
    {:noreply, %{state | queue: MapSet.put(state.queue, callsign)}}
  end

  @impl true
  def handle_info(:tick, state) do
    timer = schedule_tick()
    new_state = process_next(%{state | timer: timer})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_cache(state.db)
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ────────────────────────────────────────────────────── queue processing ──

  defp process_next(%{queue: queue} = state) do
    case Enum.at(queue, 0) do
      nil ->
        state

      callsign ->
        remaining = MapSet.delete(queue, callsign)
        state = %{state | queue: remaining}

        if get_cached(callsign) || negatively_cached?(callsign) do
          process_next(state)
        else
          do_fetch(callsign, state)
        end
    end
  end

  defp do_fetch(callsign, state) do
    if not TimeSync.synchronized?() do
      Logger.debug("[Skylink.FlightStatus] Clock not synced — deferring #{callsign}")
      %{state | queue: MapSet.put(state.queue, callsign)}
    else
      do_fetch_http(callsign, state)
    end
  end

  defp do_fetch_http(callsign, state) do
    case FlightAware.fetch(callsign) do
      {:ok, flight_info} ->
        Logger.debug("[Skylink.FlightStatus] Enriched #{callsign} via FlightAware")
        new_state = cache_put(callsign, flight_info, state)
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:flight_enriched, callsign, flight_info})
        new_state

      {:error, fa_reason} ->
        Logger.debug(
          "[Skylink.FlightStatus] FlightAware failed for #{callsign}: #{inspect(fa_reason)}, trying FlightStats"
        )

        do_fetch_flightstats(callsign, fa_reason, state)
    end
  end

  defp do_fetch_flightstats(callsign, fa_reason, state) do
    case FlightStats.fetch(callsign) do
      {:ok, flight_info} ->
        Logger.debug("[Skylink.FlightStatus] Enriched #{callsign} via FlightStats")
        new_state = cache_put(callsign, flight_info, state)
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:flight_enriched, callsign, flight_info})
        new_state

      {:error, fs_reason} ->
        if permanent_failure?(fa_reason) and permanent_failure?(fs_reason) do
          Logger.debug(
            "[Skylink.FlightStatus] Both FlightAware and FlightStats permanently failed for #{callsign}: " <>
              "FA=#{inspect(fa_reason)}, FS=#{inspect(fs_reason)}, negative-caching"
          )

          negative_cache_put(callsign, state)
        else
          Logger.debug(
            "[Skylink.FlightStatus] FlightStats failed for #{callsign}: #{inspect(fs_reason)}, trying Skylink API"
          )

          do_fetch_skylink(callsign, state)
        end
    end
  end

  # Errors that indicate the callsign will never enrich successfully — cache negatively.
  defp permanent_failure?(:unknown_callsign), do: true
  defp permanent_failure?(:no_flight_data), do: true
  defp permanent_failure?(:no_bootstrap_data), do: true
  defp permanent_failure?({:http_status, 404}), do: true
  defp permanent_failure?(_), do: false

  defp do_fetch_skylink(callsign, state) do
    cond do
      not credentials_configured?() ->
        Logger.warning(
          "[Skylink.FlightStatus] No API key configured, skipping Skylink enrichment for #{callsign}"
        )

        state

      state.call_count >= @monthly_call_cap ->
        Logger.warning(
          "[Skylink.FlightStatus] Monthly cap of #{@monthly_call_cap} calls reached — skipping #{callsign}. " <>
            "Cap resets on the 1st of next month."
        )

        state

      true ->
        do_fetch_skylink_http(callsign, state)
    end
  end

  defp do_fetch_skylink_http(callsign, state) do
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
            new_state = cache_put(callsign, flight_info, state)

            Phoenix.PubSub.broadcast(@pubsub, @topic, {:flight_enriched, callsign, flight_info})
            Logger.debug("[Skylink.FlightStatus] Enriched #{callsign}")

            # Increment monthly counter
            new_count = new_state.call_count + 1
            CubDB.put(new_state.db, {:calls, new_state.month_key}, new_count)
            Phoenix.PubSub.broadcast(@pubsub, "config", {:skylink_usage, new_count})

            # Reset counter if month rolled over
            current_month = month_key()

            if current_month != new_state.month_key do
              CubDB.put(new_state.db, {:calls, current_month}, 1)
              %{new_state | call_count: 1, month_key: current_month}
            else
              %{new_state | call_count: new_count}
            end

          :error ->
            Logger.debug("[Skylink.FlightStatus] No usable flight data for #{callsign}")
            state
        end

      {:ok, %{status: 404}} ->
        Logger.debug("[Skylink.FlightStatus] Flight not found: #{callsign}")
        negative_cache_put(callsign, state)

      {:ok, %{status: 429}} ->
        Logger.warning("[Skylink.FlightStatus] Rate limited (429) for #{callsign}")
        state

      {:ok, %{status: status}} ->
        Logger.warning("[Skylink.FlightStatus] Unexpected status #{status} for #{callsign}")
        state

      {:error, reason} ->
        Logger.warning("[Skylink.FlightStatus] HTTP error for #{callsign}: #{inspect(reason)}")

        state
    end
  end

  # ───────────────────────────────────────────────────────── parse helpers ──

  defp parse_flight(%{"flight_number" => _, "status" => status} = body) do
    # Extract airport structs first so we can look up their timezones
    dep_airport = parse_airport(body["departure"])
    arr_airport = parse_airport(body["arrival"])

    dep_tz = AirportTimezones.timezone_for(dep_airport && dep_airport.iata)
    arr_tz = AirportTimezones.timezone_for(arr_airport && arr_airport.iata)

    info =
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
      }
      |> Map.put(:status, status)

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

          # Create DateTime in the airport's local timezone, then shift to UTC
          case DateTime.new(date, time, timezone) do
            {:ok, local_dt} ->
              case DateTime.shift_zone(local_dt, "Etc/UTC") do
                {:ok, utc_dt} -> utc_dt
                _ -> nil
              end

            # If timezone creation fails, fall back to treating the time as UTC
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

  # If the date represented by {day, month} in the current year is more than
  # 7 days in the past, assume it belongs to next year (year-boundary flight).
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

  # ───────────────────────────────────────────────────────────── ETS cache ──

  defp cache_put(callsign, flight_info, state) do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {callsign, flight_info, now})
    CubDB.put(state.db, callsign, {flight_info, now})
    state
  end

  defp negative_cache_put(callsign, state) do
    now = System.system_time(:second)
    :ets.insert(@cache_table, {callsign, :not_found, now})
    CubDB.put(state.db, callsign, {:not_found, now})
    state
  end

  # Returns true when the scheduled arrival time + buffer has already passed,
  # meaning the cache entry should be treated as stale. Since arrival_time is
  # now a correctly-converted UTC DateTime, a simple Unix comparison is enough.
  defp flight_arrived?(%FlightInfo{arrival_time: nil}, _now), do: false

  defp flight_arrived?(%FlightInfo{arrival_time: arr}, now) do
    DateTime.to_unix(arr) + @arrival_buffer_sec < now
  end

  # ──────────────────────────────────────────────────────────── scheduling ──

  defp schedule_tick do
    Process.send_after(self(), :tick, @rate_limit_ms)
  end

  # Run once every 24 hours
  @prune_interval_ms 24 * 60 * 60 * 1_000

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_cache(db) do
    now = System.system_time(:second)

    # Delete callsign entries whose 24h TTL has expired (both positive and negative cache entries)
    expired_keys =
      CubDB.select(db)
      |> Stream.filter(fn
        {key, {:not_found, cached_at}} when is_binary(key) -> now - cached_at >= @cache_ttl_sec
        {key, {_info, cached_at}} when is_binary(key) -> now - cached_at >= @cache_ttl_sec
        _ -> false
      end)
      |> Enum.map(fn {key, _} -> key end)

    # Delete call-counter entries older than 2 months
    current = Date.utc_today()
    cutoff = Date.add(current, -60)

    old_month_keys =
      CubDB.select(db)
      |> Stream.filter(fn
        {{:calls, month_str}, _} ->
          case Date.from_iso8601("#{month_str}-01") do
            {:ok, d} -> Date.before?(d, cutoff)
            _ -> false
          end

        _ ->
          false
      end)
      |> Enum.map(fn {key, _} -> key end)

    all_keys = expired_keys ++ old_month_keys

    if all_keys != [] do
      CubDB.delete_multi(db, all_keys)
      CubDB.compact(db)

      Logger.debug(
        "[Skylink.FlightStatus] Pruned #{length(expired_keys)} expired entries, #{length(old_month_keys)} old month counters"
      )
    end
  end

  # ─────────────────────────────────────────────────────── month helpers ──

  defp month_key do
    date = Date.utc_today()
    "#{date.year}-#{String.pad_leading(to_string(date.month), 2, "0")}"
  end

  # ────────────────────────────────────────────────────────────── config ──

  defp credentials_configured? do
    key = Store.get(:skylink_api_key)
    is_binary(key) and key != ""
  end

  defp api_key do
    Store.get(:skylink_api_key)
  end
end
