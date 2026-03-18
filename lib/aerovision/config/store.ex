defmodule AeroVision.Config.Store do
  @moduledoc """
  Persistent key-value configuration store backed by a JSON file.

  Settings are written atomically: the JSON is first written to a `.tmp` file
  in the same directory, then renamed over the real file. On POSIX systems
  `rename(2)` is atomic, so a crash mid-write never produces a partial or
  corrupt settings file — the worst case is that the last change is lost, not
  that the entire file is unreadable.

  Publishes `{:config_changed, key, value}` to the AeroVision.PubSub topic
  "config" whenever a value changes.
  """
  use GenServer

  require Logger

  @pubsub AeroVision.PubSub
  @topic "config"
  @file_name "settings.json"

  @defaults %{
    wifi_ssid: nil,
    wifi_password: nil,
    location_lat: 35.7721,
    location_lon: -78.63861,
    radius_km: 40.234,
    tracked_flights: [],
    airline_filters: [],
    airport_filters: [],
    display_brightness: 80,
    display_cycle_seconds: 15,
    display_mode: :nearby,
    units: :imperial,
    timezone: "America/New_York",
    skylink_api_key: nil,
    opensky_client_id: nil,
    opensky_client_secret: nil,
    api_keys_seen: false
  }

  # Keys whose values are atoms (need string→atom conversion on read)
  @atom_keys [:display_mode, :units]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a config value by key. Returns default if not set."
  def get(key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc "Set a config value. Broadcasts change via PubSub."
  def put(key, value) when is_atom(key) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc "Get all configuration as a map."
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Reset all configuration to defaults."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Subscribe to config changes."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, data_dir())
    File.mkdir_p!(data_dir)
    file_path = Path.join(data_dir, @file_name)

    stored = load_file(file_path)

    stored =
      if Keyword.has_key?(opts, :data_dir) do
        # Custom data_dir means a test-isolated instance — skip .env seeding
        stored
      else
        seed_from_env(stored, file_path)
      end

    {:ok, %{file_path: file_path, stored: stored}}
  end

  @impl true
  def handle_call({:get, key}, _from, %{stored: stored} = state) do
    value = Map.get(stored, key, Map.get(@defaults, key))
    {:reply, value, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, %{file_path: file_path, stored: stored} = state) do
    stored = Map.put(stored, key, value)
    write_file(file_path, stored)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_changed, key, value})
    Logger.info("Config updated: #{key}")
    {:reply, :ok, %{state | stored: stored}}
  end

  @impl true
  def handle_call(:all, _from, %{stored: stored} = state) do
    config = Map.merge(@defaults, stored)
    {:reply, config, state}
  end

  @impl true
  def handle_call(:reset, _from, %{file_path: file_path} = state) do
    write_file(file_path, %{})
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_reset})
    {:reply, :ok, %{state | stored: %{}}}
  end

  # ---------------------------------------------------------------------------
  # File I/O
  # ---------------------------------------------------------------------------

  # Read and decode the JSON settings file. Returns a map with atom keys.
  # Returns %{} on any error (missing file, parse error) so defaults are used.
  defp load_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) ->
            decode_stored(map)

          _ ->
            Logger.warning("[Config.Store] Could not parse #{path} — using defaults")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning(
          "[Config.Store] Could not read #{path}: #{inspect(reason)} — using defaults"
        )

        %{}
    end
  end

  # Atomically write the settings map to disk as JSON.
  # Write to a .tmp file first, then rename over the real file.
  defp write_file(path, stored) do
    tmp = path <> ".tmp"

    case Jason.encode(encode_stored(stored), pretty: true) do
      {:ok, json} ->
        case File.write(tmp, json) do
          :ok ->
            case File.rename(tmp, path) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.error(
                  "[Config.Store] Failed to rename #{tmp} → #{path}: #{inspect(reason)}"
                )
            end

          {:error, reason} ->
            Logger.error("[Config.Store] Failed to write #{tmp}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("[Config.Store] Failed to encode config to JSON: #{inspect(reason)}")
    end
  end

  # Encode stored map for JSON: convert atom values to strings for known keys.
  defp encode_stored(stored) do
    stored
    |> Enum.map(fn {k, v} ->
      v =
        cond do
          is_atom(v) and not is_nil(v) and not is_boolean(v) -> Atom.to_string(v)
          true -> v
        end

      {Atom.to_string(k), v}
    end)
    |> Map.new()
  end

  # Decode a JSON-decoded map (string keys, string values) back to atom keys/values.
  defp decode_stored(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      case parse_key(k) do
        nil -> []
        key -> [{key, decode_value(key, v)}]
      end
    end)
    |> Map.new()
  end

  # Only accept keys that are known config keys — ignore anything else.
  defp parse_key(str) do
    key = String.to_existing_atom(str)
    if Map.has_key?(@defaults, key), do: key, else: nil
  rescue
    ArgumentError -> nil
  end

  # Decode a value, restoring atoms for known atom-valued keys.
  defp decode_value(key, value) when key in @atom_keys and is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp decode_value(_key, value), do: value

  # ---------------------------------------------------------------------------
  # Build-time env seeding
  # ---------------------------------------------------------------------------

  # Seed settings from values baked into the firmware at build time via
  # config/config.exs → Application.get_env(:aerovision, :env_seeds).
  # Raw values are strings (from the .env file); each needs type coercion.
  # Only seeds keys that are blank in stored — UI changes always win.
  defp seed_from_env(stored, file_path) do
    seeds = Application.get_env(:aerovision, :env_seeds, %{})

    updated =
      seeds
      |> Enum.reduce(stored, fn {config_key, raw}, acc ->
        with raw when is_binary(raw) and raw != "" <- raw,
             {:ok, value} <- coerce(config_key, raw),
             true <- blank_in_stored?(acc, config_key) do
          Logger.info("[Config.Store] Seeded #{config_key} from build-time env")
          Map.put(acc, config_key, value)
        else
          _ -> acc
        end
      end)

    # :radius_mi is a special case — it maps to :radius_km after conversion
    updated =
      case Map.get(seeds, :radius_mi) do
        raw when is_binary(raw) and raw != "" ->
          if blank_in_stored?(updated, :radius_km) do
            case parse_miles(raw) do
              {:ok, km} ->
                Logger.info("[Config.Store] Seeded radius_km from RADIUS_MI (#{raw} mi)")
                Map.put(updated, :radius_km, km)

              :error ->
                updated
            end
          else
            updated
          end

        _ ->
          updated
      end

    if updated != stored do
      write_file(file_path, updated)
    end

    updated
  end

  # Type-coerce a raw string value for the given config key.
  defp coerce(key, raw) when key in [:location_lat, :location_lon, :radius_km] do
    case Float.parse(raw) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  defp coerce(key, raw)
       when key in [:display_brightness, :display_cycle_seconds] do
    case Integer.parse(raw) do
      {i, _} -> {:ok, i}
      :error -> :error
    end
  end

  defp coerce(:display_mode, "nearby"), do: {:ok, :nearby}
  defp coerce(:display_mode, "tracked"), do: {:ok, :tracked}
  defp coerce(:display_mode, _), do: :error

  defp coerce(:units, "imperial"), do: {:ok, :imperial}
  defp coerce(:units, "metric"), do: {:ok, :metric}
  defp coerce(:units, _), do: :error

  defp coerce(key, raw) when key in [:tracked_flights, :airline_filters, :airport_filters] do
    items =
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, items}
  end

  defp coerce(:timezone, raw) when is_binary(raw) and raw != "", do: {:ok, raw}

  # :radius_mi is handled separately above — skip here
  defp coerce(:radius_mi, _), do: :error

  defp coerce(_key, raw), do: {:ok, raw}

  defp parse_miles(s) do
    case Float.parse(s) do
      {miles, _} -> {:ok, Float.round(miles * 1.60934, 3)}
      :error -> :error
    end
  end

  # A key is "blank" if it's missing, nil, or an empty list/string.
  defp blank_in_stored?(stored, key) do
    case Map.get(stored, key) do
      nil -> true
      "" -> true
      [] -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp data_dir do
    case Application.get_env(:aerovision, :target, :host) do
      target when target in [:host, :test] ->
        Path.join(System.user_home!(), ".aerovision/config")

      _ ->
        "/data/aerovision/config"
    end
  end
end
