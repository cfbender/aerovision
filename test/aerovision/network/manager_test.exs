defmodule AeroVision.Network.ManagerTest do
  use ExUnit.Case, async: false

  # AeroVision.PubSub and AeroVision.Config.Store are started by the application
  # supervisor (target: :test in config/test.exs). Tests must NOT re-start them.

  alias AeroVision.Config.Store
  alias AeroVision.Network.Manager

  # ── setup ──────────────────────────────────────────────────────────────────
  # Subscribe to "network" BEFORE starting Manager so we catch any broadcast
  # emitted during init/1 (which runs synchronously in start_supervised!).

  setup do
    Store.reset()

    # Subscribe before starting Manager so we catch init broadcasts
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "network")

    start_supervised!(Manager)
    :ok
  end

  # ── initial state ───────────────────────────────────────────────────────────

  test "with no credentials stored, mode is :ap on init" do
    # Store.reset() cleared credentials, so Manager should start in AP mode
    assert Manager.current_mode() == :ap
  end

  test "with no credentials, {:network, :ap_mode} is broadcast on init" do
    assert_receive {:network, :ap_mode}
  end

  test "with credentials stored, mode is :infrastructure on init" do
    # Stop Manager, set credentials, restart
    stop_supervised!(Manager)
    Store.put(:wifi_ssid, "MyNetwork")
    Store.put(:wifi_password, "secret123")

    # Drain any pending network messages
    receive do
      {:network, _} -> :ok
    after
      50 -> :ok
    end

    start_supervised!(Manager)

    assert Manager.current_mode() == :infrastructure
  end

  test "with credentials, no :ap_mode broadcast on init" do
    stop_supervised!(Manager)
    Store.put(:wifi_ssid, "MyNetwork")
    Store.put(:wifi_password, "secret123")

    # Drain previous ap_mode broadcast
    receive do
      {:network, :ap_mode} -> :ok
    after
      50 -> :ok
    end

    start_supervised!(Manager)
    refute_receive {:network, :ap_mode}, 100
  end

  # ── current_mode/0 ──────────────────────────────────────────────────────────

  test "current_mode/0 returns current mode atom" do
    mode = Manager.current_mode()
    assert mode in [:ap, :infrastructure, :disconnected]
  end

  # ── current_ip/0 ────────────────────────────────────────────────────────────

  test "current_ip/0 returns '127.0.0.1' on host" do
    ip = Manager.current_ip()
    # On host, fetch_ip returns "127.0.0.1"
    assert ip == "127.0.0.1"
  end

  # ── connect_wifi/2 ──────────────────────────────────────────────────────────

  test "connect_wifi/2 saves ssid to Config.Store" do
    Manager.connect_wifi("TestSSID", "password123")
    assert Store.get(:wifi_ssid) == "TestSSID"
  end

  test "connect_wifi/2 saves password to Config.Store" do
    Manager.connect_wifi("TestSSID", "password123")
    assert Store.get(:wifi_password) == "password123"
  end

  test "connect_wifi/2 returns :ok" do
    result = Manager.connect_wifi("TestSSID", "password123")
    assert result == :ok
  end

  test "connect_wifi/2 switches mode to :connecting" do
    # Start in AP mode (no credentials)
    assert Manager.current_mode() == :ap
    Manager.connect_wifi("TestSSID", "password123")
    assert Manager.current_mode() == :connecting
  end

  # ── force_ap_mode/0 ─────────────────────────────────────────────────────────

  test "force_ap_mode/0 returns :ok (cast is async, returns :ok immediately)" do
    result = Manager.force_ap_mode()
    assert result == :ok
  end

  test "force_ap_mode/0 switches mode to :ap" do
    # First trigger a connecting state
    Manager.connect_wifi("TestSSID", "pass123")
    assert Manager.current_mode() == :connecting

    Manager.force_ap_mode()
    _ = Manager.current_mode()
    assert Manager.current_mode() == :ap
  end

  test "force_ap_mode/0 broadcasts {:network, :ap_mode}" do
    # Drain the init broadcast
    receive do
      {:network, :ap_mode} -> :ok
    after
      100 -> :ok
    end

    Manager.connect_wifi("TestSSID", "pass123")
    # Drain :connecting broadcast
    receive do
      {:network, _} -> :ok
    after
      50 -> :ok
    end

    Manager.force_ap_mode()
    assert_receive {:network, :ap_mode}
  end

  # ── scan_networks/0 ─────────────────────────────────────────────────────────

  test "scan_networks/0 returns [] on host" do
    result = Manager.scan_networks()
    assert result == []
  end

  # ── config_changed messages ─────────────────────────────────────────────────

  test "{:config_changed, ...} messages are ignored — connections are explicit only" do
    # Saving credentials to the store must NOT trigger an automatic connection,
    # as that would tear down the AP during the setup wizard.
    Store.put(:wifi_ssid, "NewSSID")
    Store.put(:wifi_password, "secret123")

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :wifi_ssid, "NewSSID"}
    )

    _ = Manager.current_mode()
    # Mode unchanged — still :ap, not :infrastructure or :connecting
    assert Manager.current_mode() == :ap
  end

  test "{:config_changed, :wifi_ssid, \"\"} with no password does not crash" do
    # No password set — credentials_present? returns false → no reconnect
    Phoenix.PubSub.broadcast(AeroVision.PubSub, "config", {:config_changed, :wifi_ssid, ""})
    _ = Manager.current_mode()
    # Should still be running fine
    assert Manager.current_mode() in [:ap, :infrastructure]
  end

  test "unrelated config changes are ignored without crash" do
    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :display_mode, :tracked}
    )

    _ = Manager.current_mode()
    # Process still alive
    assert is_pid(GenServer.whereis(Manager))
  end

  # ── VintageNet-format messages ───────────────────────────────────────────────

  test ":internet connection event switches mode to :infrastructure" do
    # Start in AP mode
    assert Manager.current_mode() == :ap

    pid = GenServer.whereis(Manager)
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :internet, %{}})
    # Sync with a call
    assert Manager.current_mode() == :infrastructure
  end

  test ":internet connection event broadcasts {:network, :connected, ip}" do
    # Drain any init broadcast
    receive do
      {:network, _} -> :ok
    after
      100 -> :ok
    end

    pid = GenServer.whereis(Manager)

    # Must be in :connecting mode for the :internet event to broadcast :connected.
    # Simulate: connect_wifi sets mode to :connecting.
    Manager.connect_wifi("TestSSID", "pass")

    receive do
      {:network, :connecting, _} -> :ok
    after
      100 -> :ok
    end

    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :internet, %{}})

    assert_receive {:network, :connected, ip}
    assert is_binary(ip)
  end

  test ":lan connection event also switches mode to :infrastructure" do
    pid = GenServer.whereis(Manager)
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :lan, %{}})
    assert Manager.current_mode() == :infrastructure
  end

  @tag :capture_log
  test ":disconnected from :infrastructure sets :disconnected mode" do
    # First move to infrastructure
    pid = GenServer.whereis(Manager)
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :internet, %{}})
    assert Manager.current_mode() == :infrastructure

    # Now disconnect
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :disconnected, %{}})
    assert Manager.current_mode() == :disconnected
  end

  @tag :capture_log
  test ":reconnect_timeout on host re-attempts infrastructure (no AP fallback, no reboot)" do
    # Seed credentials so the host-path re-attempt has something to work with
    stop_supervised!(Manager)
    Store.put(:wifi_ssid, "MyNetwork")
    Store.put(:wifi_password, "secret123")
    start_supervised!(Manager)

    pid = GenServer.whereis(Manager)

    # Move to infrastructure
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :internet, %{}})
    assert Manager.current_mode() == :infrastructure

    # Disconnect (starts timer)
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :disconnected, %{}})
    assert Manager.current_mode() == :disconnected

    # Drain any prior network broadcasts
    receive do
      {:network, _} -> :ok
    after
      50 -> :ok
    end

    # Manually trigger the reconnect timeout
    send(pid, :reconnect_timeout)

    # Sync with a call to ensure the message was handled
    _ = Manager.current_mode()

    # On host: no reboot, no AP mode — mode stays :disconnected, no :ap_mode broadcast
    refute_receive {:network, :ap_mode}, 100
    assert Manager.current_mode() == :disconnected
  end

  test ":disconnected while in :ap mode takes no action" do
    assert Manager.current_mode() == :ap
    pid = GenServer.whereis(Manager)
    send(pid, {VintageNet, ["interface", "wlan0", "connection"], nil, :disconnected, %{}})
    # Mode should remain :ap, no crash
    assert Manager.current_mode() == :ap
  end
end
