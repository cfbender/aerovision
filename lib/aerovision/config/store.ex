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
    location_lat: 35.7796,
    location_lon: -78.6382,
    radius_km: 50,
    tracked_flights: [],
    airline_filters: [],
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
  def init(_opts) do
    data_dir = data_dir()
    File.mkdir_p!(data_dir)
    db = AeroVision.DB.open(data_dir: data_dir)
    {:ok, %{db: db}}
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
    stored = CubDB.select(db) |> Enum.into(%{})
    config = Map.merge(@defaults, stored)
    {:reply, config, state}
  end

  @impl true
  def handle_call(:reset, _from, %{db: db} = state) do
    CubDB.clear(db)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_reset})
    {:reply, :ok, state}
  end

  defp data_dir do
    if Application.get_env(:aerovision, :target, :host) == :host do
      Path.join(System.user_home!(), ".aerovision/config")
    else
      "/data/aerovision/config"
    end
  end
end
