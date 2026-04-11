import Config

# Runtime configuration — loaded at boot on target, at app start on host.

# ---------------------------------------------------------------------------
# Per-device setup AP SSID
#
# Ensure VintageNet boots wlan0 AP mode with a unique SSID per device (derived
# from wlan0 MAC suffix) before any apps start. This avoids AP runtime
# reconfiguration churn and the DHCP instability it can cause on Pi Zero 2 W.
#
# If MAC is unavailable, fallback remains the base SSID.
# ---------------------------------------------------------------------------
target = Application.get_env(:aerovision, :target, :host)

setup_ap_ssid_base = "AeroVision-Setup"
setup_ap_interface = "wlan0"
setup_ap_ip = "192.168.24.1"
setup_ap_dhcp_start = "192.168.24.2"
setup_ap_dhcp_end = "192.168.24.200"
setup_ap_max_leases = 128

read_mac = fn interface ->
  path = Path.join(["/sys/class/net", interface, "address"])

  case File.read(path) do
    {:ok, mac} -> String.trim(mac)
    {:error, _reason} -> nil
  end
end

mac_suffix = fn
  mac when is_binary(mac) ->
    cleaned =
      mac
      |> String.trim()
      |> String.replace(":", "")
      |> String.replace("-", "")
      |> String.upcase()

    if String.match?(cleaned, ~r/\A[0-9A-F]{12}\z/) do
      String.slice(cleaned, byte_size(cleaned) - 4, 4)
    end

  _ ->
    nil
end

setup_ap_ssid =
  case mac_suffix.(read_mac.(setup_ap_interface)) do
    nil -> setup_ap_ssid_base
    suffix -> "#{setup_ap_ssid_base}-#{suffix}"
  end

config_store_path =
  case target do
    t when t in [:host, :test] ->
      Path.join([System.user_home!(), ".aerovision/config/settings.json"])

    _ ->
      "/data/aerovision/config/settings.json"
  end

force_ap_on_boot? =
  case File.read(config_store_path) do
    {:ok, settings_json} ->
      case Jason.decode(settings_json) do
        {:ok, %{"wifi_force_ap" => true}} -> true
        _ -> false
      end

    {:error, _reason} ->
      false
  end

vintage_net_config = Application.get_env(:vintage_net, :config, [])
vintage_net_available? = not is_nil(Application.spec(:vintage_net))

ap_wlan0_config = %{
  type: VintageNetWiFi,
  vintage_net_wifi: %{
    networks: [%{mode: :ap, ssid: setup_ap_ssid, key_mgmt: :none}]
  },
  ipv4: %{
    method: :static,
    address: setup_ap_ip,
    netmask: "255.255.255.0"
  },
  dhcpd: %{
    start: setup_ap_dhcp_start,
    end: setup_ap_dhcp_end,
    max_leases: setup_ap_max_leases
  }
}

updated_vintage_net_config =
  Enum.map(vintage_net_config, fn
    {"wlan0", %{vintage_net_wifi: %{networks: [%{mode: :ap} = network | rest]} = wifi} = wlan_config} ->
      if force_ap_on_boot? do
        {"wlan0", ap_wlan0_config}
      else
        updated_network = Map.put(network, :ssid, setup_ap_ssid)
        updated_wifi = Map.put(wifi, :networks, [updated_network | rest])
        {"wlan0", Map.put(wlan_config, :vintage_net_wifi, updated_wifi)}
      end

    {"wlan0", wlan_config} ->
      if force_ap_on_boot? do
        {"wlan0", ap_wlan0_config}
      else
        {"wlan0", wlan_config}
      end

    entry ->
      entry
  end)

config :aerovision, :setup_ap_ssid, setup_ap_ssid
config :aerovision, :wifi_force_ap_on_boot, force_ap_on_boot?

if vintage_net_available? do
  config :vintage_net, config: updated_vintage_net_config
end
