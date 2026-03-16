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
    display_cycle_seconds: 8,
    display_mode: :nearby,
    poll_interval_sec: 15,
    units: :imperial,
    opensky_client_id: nil,
    opensky_client_secret: nil,
    aeroapi_key: nil
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
  # .env seeding
  # ---------------------------------------------------------------------------

  # Seed API keys from environment variables on first boot.
  # Only writes keys that aren't already stored — manual Settings changes
  # always take precedence over .env values.
  defp seed_from_env(stored, file_path) do
    load_dot_env()

    updated =
      [
        {"OPENSKY_CLIENT_ID", :opensky_client_id},
        {"OPENSKY_CLIENT_SECRET", :opensky_client_secret},
        {"AEROAPI_KEY", :aeroapi_key}
      ]
      |> Enum.reduce(stored, fn {env_var, config_key}, acc ->
        with value when is_binary(value) and value != "" <- System.get_env(env_var),
             true <- not Map.has_key?(acc, config_key) or is_nil(Map.get(acc, config_key)) do
          Logger.info("[Config.Store] Seeded #{config_key} from environment")
          Map.put(acc, config_key, value)
        else
          _ -> acc
        end
      end)

    if updated != stored do
      write_file(file_path, updated)
    end

    updated
  end

  # Parse a .env file from the project root and load its KEY=VALUE pairs
  # into the process environment. Only runs on host (dev/test), not on target.
  # Silently skips if the file doesn't exist or can't be read.
  defp load_dot_env do
    if Application.get_env(:aerovision, :target, :host) in [:host, :test] do
      dot_env_path =
        case Application.get_env(:aerovision, :dot_env_path) do
          nil -> Path.join(File.cwd!(), ".env")
          path -> path
        end

      case File.read(dot_env_path) do
        {:ok, contents} ->
          contents
          |> String.split("\n", trim: true)
          |> Enum.each(fn line ->
            line = String.trim(line)

            cond do
              line == "" or String.starts_with?(line, "#") ->
                :ok

              String.contains?(line, "=") ->
                [key | rest] = String.split(line, "=", parts: 2)
                key = String.trim(key)
                value = rest |> Enum.join("=") |> String.trim()

                value =
                  cond do
                    String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
                      String.slice(value, 1..-2//1)

                    String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
                      String.slice(value, 1..-2//1)

                    true ->
                      value
                  end

                if key != "" and value != "", do: System.put_env(key, value)

              true ->
                :ok
            end
          end)

        {:error, _} ->
          :ok
      end
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
