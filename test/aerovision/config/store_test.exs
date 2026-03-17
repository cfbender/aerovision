defmodule AeroVision.Config.StoreTest do
  use ExUnit.Case, async: false

  alias AeroVision.Config.Store

  # Each test gets its own isolated Config.Store instance backed by a temp
  # directory. This prevents races with the app-supervised Store used by other
  # test files (ManagerTest, TrackerTest, etc.) which also call Store.reset().
  setup do
    tmp = Path.join(System.tmp_dir!(), "store_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Start a private Store under a unique name so it doesn't clash with the
    # app-supervised Store.__MODULE__ registered name.
    name = :"store_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Store, [data_dir: tmp], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    # Subscribe to config changes via the private store's PubSub broadcasts.
    Store.subscribe()

    %{store: name, tmp: tmp, pid: pid}
  end

  # Helper: call the per-test Store instance by name
  defp get(name, key), do: GenServer.call(name, {:get, key})
  defp put(name, key, val), do: GenServer.call(name, {:put, key, val})
  defp all(name), do: GenServer.call(name, :all)
  defp reset(name), do: GenServer.call(name, :reset)

  # ── get/1 ────────────────────────────────────────────────────────────────────

  test "get/1 returns default for unset key", %{store: store} do
    assert get(store, :location_lat) == 35.7721
    assert get(store, :location_lon) == -78.63861
    assert get(store, :radius_km) == 40.234
    assert get(store, :tracked_flights) == []
    assert get(store, :airline_filters) == []
    assert get(store, :display_mode) == :nearby
    assert get(store, :display_brightness) == 80
    assert get(store, :display_cycle_seconds) == 15
    assert get(store, :units) == :imperial
  end

  test "get/1 returns nil for unset optional keys", %{store: store} do
    assert is_nil(get(store, :wifi_ssid))
    assert is_nil(get(store, :wifi_password))
    assert is_nil(get(store, :skylink_api_key))
    assert is_nil(get(store, :opensky_client_id))
    assert is_nil(get(store, :opensky_client_secret))
  end

  test "get/1 returns stored value after put/2", %{store: store} do
    put(store, :location_lat, 40.7128)
    assert get(store, :location_lat) == 40.7128
  end

  test "get/1 returns latest value after multiple puts", %{store: store} do
    put(store, :radius_km, 100)
    put(store, :radius_km, 75)
    assert get(store, :radius_km) == 75
  end

  # ── put/2 ────────────────────────────────────────────────────────────────────

  test "put/2 returns :ok", %{store: store} do
    assert put(store, :location_lat, 40.0) == :ok
  end

  test "put/2 broadcasts {:config_changed, key, value} on PubSub", %{store: store} do
    put(store, :radius_km, 25)
    assert_receive {:config_changed, :radius_km, 25}
  end

  test "put/2 broadcasts with correct value types", %{store: store} do
    put(store, :display_mode, :tracked)
    assert_receive {:config_changed, :display_mode, :tracked}

    put(store, :tracked_flights, ["AAL1234", "DAL567"])
    assert_receive {:config_changed, :tracked_flights, ["AAL1234", "DAL567"]}

    put(store, :wifi_ssid, "MyNetwork")
    assert_receive {:config_changed, :wifi_ssid, "MyNetwork"}
  end

  test "put/2 can store lists as values", %{store: store} do
    put(store, :tracked_flights, ["AAL1234"])
    assert get(store, :tracked_flights) == ["AAL1234"]

    put(store, :airline_filters, ["AAL", "DAL"])
    assert get(store, :airline_filters) == ["AAL", "DAL"]
  end

  # ── all/0 ────────────────────────────────────────────────────────────────────

  test "all/0 contains all default keys with default values", %{store: store} do
    config = all(store)

    assert config.location_lat == 35.7721
    assert config.location_lon == -78.63861
    assert config.radius_km == 40.234
    assert config.tracked_flights == []
    assert config.airline_filters == []
    assert config.display_brightness == 80
    assert config.display_cycle_seconds == 15
    assert config.display_mode == :nearby
    assert config.units == :imperial
  end

  test "all/0 shows stored values for keys that have been put", %{store: store} do
    put(store, :location_lat, 40.7128)
    put(store, :radius_km, 25)

    config = all(store)

    assert config.location_lat == 40.7128
    assert config.radius_km == 25
    assert config.location_lon == -78.63861
  end

  # ── reset/0 ──────────────────────────────────────────────────────────────────

  test "reset/0 clears stored values — get/1 returns defaults again", %{store: store} do
    put(store, :location_lat, 40.0)
    put(store, :radius_km, 100)

    assert get(store, :location_lat) == 40.0
    assert get(store, :radius_km) == 100

    reset(store)

    assert get(store, :location_lat) == 35.7721
    assert get(store, :radius_km) == 40.234
  end

  test "reset/0 returns :ok", %{store: store} do
    assert reset(store) == :ok
  end

  test "reset/0 broadcasts {:config_reset}", %{store: store} do
    # Drain any stale reset message
    receive do
      {:config_reset} -> :ok
    after
      0 -> :ok
    end

    reset(store)
    assert_receive {:config_reset}
  end

  test "reset/0 — all/0 returns only defaults after reset", %{store: store} do
    put(store, :location_lat, 99.0)
    put(store, :display_mode, :tracked)
    reset(store)

    config = all(store)
    assert config.location_lat == 35.7721
    assert config.display_mode == :nearby
  end

  # ── subscribe/0 ──────────────────────────────────────────────────────────────

  test "subscribe/0 lets caller receive config_changed messages", %{store: store} do
    put(store, :units, :metric)
    assert_receive {:config_changed, :units, :metric}
  end

  test "subscriber receives multiple broadcasts in order", %{store: store} do
    put(store, :radius_km, 10)
    put(store, :radius_km, 20)
    put(store, :radius_km, 30)

    assert_receive {:config_changed, :radius_km, 10}
    assert_receive {:config_changed, :radius_km, 20}
    assert_receive {:config_changed, :radius_km, 30}
  end

  # ── persistence ──────────────────────────────────────────────────────────────

  test "values survive stop/restart of the Store process", %{store: store, tmp: tmp, pid: pid} do
    put(store, :location_lat, 51.5074)
    put(store, :display_mode, :tracked)

    # Stop the store — JSON is already flushed to disk on each put
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    # Restart on the same data_dir — should load persisted values from JSON
    name2 = :"store_restart_#{System.unique_integer([:positive])}"
    {:ok, pid2} = GenServer.start_link(Store, [data_dir: tmp], name: name2)

    assert get(name2, :location_lat) == 51.5074
    assert get(name2, :display_mode) == :tracked

    GenServer.stop(pid2)
  end

  test "reset clears all previously stored values", %{store: store} do
    put(store, :location_lat, 51.5074)
    put(store, :display_mode, :tracked)
    reset(store)

    assert get(store, :location_lat) == 35.7721
    assert get(store, :display_mode) == :nearby
  end

  test "stored values appear in all/0", %{store: store} do
    put(store, :radius_km, 123)
    config = all(store)
    assert config.radius_km == 123
  end

  test "atom values round-trip through JSON correctly", %{store: store, tmp: tmp, pid: pid} do
    put(store, :display_mode, :tracked)
    put(store, :units, :metric)

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    name2 = :"store_atom_#{System.unique_integer([:positive])}"
    {:ok, pid2} = GenServer.start_link(Store, [data_dir: tmp], name: name2)

    assert get(name2, :display_mode) == :tracked
    assert get(name2, :units) == :metric

    GenServer.stop(pid2)
  end

  test "JSON file is created on first put", %{store: store, tmp: tmp} do
    refute File.exists?(Path.join(tmp, "settings.json"))
    put(store, :location_lat, 1.0)
    assert File.exists?(Path.join(tmp, "settings.json"))
  end

  test "unknown keys in JSON file are ignored on load", %{tmp: tmp} do
    json = Jason.encode!(%{"unknown_key" => "value", "location_lat" => 42.0})
    File.write!(Path.join(tmp, "settings.json"), json)

    name = :"store_unknown_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Store, [data_dir: tmp], name: name)

    assert get(name, :location_lat) == 42.0
    # Unknown key doesn't crash and doesn't appear in all/0
    config = all(name)
    refute Map.has_key?(config, :unknown_key)

    GenServer.stop(pid)
  end

  @tag :capture_log
  test "corrupt JSON file falls back to defaults", %{tmp: tmp} do
    File.write!(Path.join(tmp, "settings.json"), "not valid json {{{{")

    name = :"store_corrupt_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Store, [data_dir: tmp], name: name)

    assert get(name, :location_lat) == 35.7721

    GenServer.stop(pid)
  end
end
