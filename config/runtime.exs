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
setup_ap_ssid_base = "AeroVision-Setup"
setup_ap_interface = "wlan0"

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

vintage_net_config = Application.get_env(:vintage_net, :config, [])
vintage_net_available? = not is_nil(Application.spec(:vintage_net))

updated_vintage_net_config =
  Enum.map(vintage_net_config, fn
    {"wlan0", %{vintage_net_wifi: %{networks: [%{mode: :ap} = network | rest]} = wifi} = wlan_config} ->
      updated_network = Map.put(network, :ssid, setup_ap_ssid)
      updated_wifi = Map.put(wifi, :networks, [updated_network | rest])
      {"wlan0", Map.put(wlan_config, :vintage_net_wifi, updated_wifi)}

    entry ->
      entry
  end)

config :aerovision, :setup_ap_ssid, setup_ap_ssid

if vintage_net_available? do
  config :vintage_net, config: updated_vintage_net_config
end
