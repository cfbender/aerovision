defmodule AeroVision.Config.Store do
  @moduledoc """
  Persistent key-value configuration store backed by CubDB.

  Stores user configuration (WiFi credentials, location, tracked flights,
  API keys, display settings) on the writable /data partition.

  Publishes `{:config_changed, key, value}` to the AeroVision.PubSub topic
  "config" whenever a value changes.
  """
  use GenServer

  require Logger

  @pubsub AeroVision.PubSub
  @topic "config"

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

  # Client API

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

  # Server callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, data_dir())
    File.mkdir_p!(data_dir)
    db = AeroVision.DB.open(data_dir: data_dir)
    # Only seed from env on normal startup — skip when a custom data_dir is
    # provided (e.g. in tests) to avoid polluting isolated test databases.
    unless Keyword.has_key?(opts, :data_dir) do
      seed_from_env(db)
    end

    {:ok, %{db: db}}
  end

  # Seed config values from environment variables (or a .env file) on startup.
  # Only writes values that aren't already stored — manual Settings changes
  # always take precedence over .env values.
  #
  # Supported env vars:
  #   OPENSKY_CLIENT_ID     → :opensky_client_id
  #   OPENSKY_CLIENT_SECRET → :opensky_client_secret
  #   AEROAPI_KEY           → :aeroapi_key
  #
  # The .env file in the project root is parsed in dev/host mode and its
  # KEY=VALUE pairs are loaded into the process environment before reading.
  defp seed_from_env(db) do
    load_dot_env()

    [
      {"OPENSKY_CLIENT_ID", :opensky_client_id},
      {"OPENSKY_CLIENT_SECRET", :opensky_client_secret},
      {"AEROAPI_KEY", :aeroapi_key}
    ]
    |> Enum.each(fn {env_var, config_key} ->
      with value when is_binary(value) and value != "" <- System.get_env(env_var),
           nil <- CubDB.get(db, config_key) do
        CubDB.put(db, config_key, value)
        Logger.info("[Config.Store] Seeded #{config_key} from environment")
      end
    end)
  end

  # Parse a .env file from the project root and load its KEY=VALUE pairs
  # into the process environment. Only runs on host (dev/test), not on target.
  # Silently skips if the file doesn't exist or can't be read.
  defp load_dot_env do
    if Application.get_env(:aerovision, :target, :host) in [:host, :test] do
      dot_env_path =
        case Application.get_env(:aerovision, :dot_env_path) do
          nil ->
            # Walk up from the app dir to find the project root .env
            app_dir = File.cwd!()
            Path.join(app_dir, ".env")

          path ->
            path
        end

      case File.read(dot_env_path) do
        {:ok, contents} ->
          contents
          |> String.split("\n", trim: true)
          |> Enum.each(fn line ->
            line = String.trim(line)

            cond do
              # Skip comments and empty lines
              line == "" or String.starts_with?(line, "#") ->
                :ok

              # KEY=VALUE (uncommented)
              String.contains?(line, "=") ->
                [key | rest] = String.split(line, "=", parts: 2)
                key = String.trim(key)
                value = rest |> Enum.join("=") |> String.trim()
                # Strip surrounding quotes if present
                value =
                  cond do
                    String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
                      String.slice(value, 1..-2//1)

                    String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
                      String.slice(value, 1..-2//1)

                    true ->
                      value
                  end

                if key != "" and value != "" do
                  System.put_env(key, value)
                end

              true ->
                :ok
            end
          end)

        {:error, _} ->
          :ok
      end
    end
  end

  @impl true
  def handle_call({:get, key}, _from, %{db: db} = state) do
    value = CubDB.get(db, key, Map.get(@defaults, key))
    {:reply, value, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, %{db: db} = state) do
    CubDB.put(db, key, value)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_changed, key, value})
    Logger.info("Config updated: #{key}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:all, _from, %{db: db} = state) do
    stored = safe_select(db)
    config = Map.merge(@defaults, stored)
    {:reply, config, state}
  end

  @impl true
  def handle_call(:reset, _from, %{db: db} = state) do
    CubDB.clear(db)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_reset})
    {:reply, :ok, state}
  end

  # CubDB select/2 can fail mid-traversal if the B-tree is in a corrupt or
  # inconsistent state (e.g. after an interrupted compaction). Return an empty
  # map on failure so callers fall back to @defaults rather than crashing.
  defp safe_select(db) do
    CubDB.select(db) |> Enum.into(%{})
  rescue
    _ ->
      Logger.error(
        "[Config.Store] CubDB select failed — returning defaults. Consider clearing ~/.aerovision/config."
      )

      %{}
  end

  defp data_dir do
    case Application.get_env(:aerovision, :target, :host) do
      target when target in [:host, :test] ->
        Path.join(System.user_home!(), ".aerovision/config")

      _ ->
        "/data/aerovision/config"
    end
  end
end
