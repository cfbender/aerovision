import Config

config :logger, backends: [RingLogger]

# Prevent Phoenix from starting the CodeReloader MixListener during compilation.
# Phoenix 1.8 registers it as a Mix.PubSub listener which fails on Nerves because
# Phoenix.CodeReloader is a dev-only module not compiled into the target.
config :phoenix, :plug_init_mode, :runtime

# Nerves target-specific configuration

config :aerovision, AeroVisionWeb.Endpoint,
  url: [host: "aerovision.local"],
  http: [ip: {0, 0, 0, 0}, port: 80],
  check_origin: false,
  server: true,
  secret_key_base: "target_secret_base_generate_with_mix_phx_gen_secret_at_least_64_bytes"

# Use shoehorn to start the main application
config :shoehorn,
  init: [:nerves_runtime, :nerves_pack, :nerves_time],
  app: Mix.Project.config()[:app]

config :nerves_runtime, :kernel, use_system_registry: false

# Configure mDNS — exclude usb0 so its 172.31.x.x address is never announced.
# if_monitor is intentionally omitted: mdns_lite auto-detects VintageNet.
config :mdns_lite,
  hosts: [:hostname, "aerovision"],
  ttl: 120,
  excluded_ifnames: ["lo0", "lo", "ppp0", "wwan0", "usb0", "__unknown"],
  services: [
    %{
      protocol: "http",
      transport: "tcp",
      port: 80
    }
  ]

# Read WiFi credentials from .env at build time so VintageNet can connect on
# first boot without runtime wlan0 reconfiguration. The brcmfmac driver on the
# Pi Zero 2 W cannot reliably transition wlan0 from scan-only to infrastructure
# mode at runtime, so credentials must be baked in before the interface starts.
{wlan0_boot_ssid, wlan0_boot_pass} =
  case File.read(Path.join(File.cwd!(), ".env")) do
    {:ok, contents} ->
      get_val = fn key, text ->
        case Regex.run(~r/^#{key}\s*=\s*['"]?([^'"\n]+)['"]?\s*$/m, text) do
          [_, val] -> String.trim(val)
          _ -> nil
        end
      end

      {get_val.("WIFI_SSID", contents), get_val.("WIFI_PASSWORD", contents)}

    _ ->
      {nil, nil}
  end

wlan0_boot_config =
  if is_binary(wlan0_boot_ssid) and wlan0_boot_ssid != "" and
       is_binary(wlan0_boot_pass) and wlan0_boot_pass != "" do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{ssid: wlan0_boot_ssid, psk: wlan0_boot_pass, key_mgmt: :wpa_psk}]
      },
      ipv4: %{method: :dhcp}
    }
  else
    %{type: VintageNetWiFi}
  end

# VintageNet boot config — wlan0 includes baked-in credentials when available
# so the brcmfmac driver can connect to WiFi immediately without a runtime
# reconfiguration step. Falls back to scan-only mode if no credentials found.
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
    {"wlan0", wlan0_boot_config}
  ]

config :nerves_time, :servers, [
  "0.pool.ntp.org",
  "1.pool.ntp.org",
  "2.pool.ntp.org",
  "3.pool.ntp.org"
]

# Disable unnecessary kernel features
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay", fwup_conf: "fwup.conf"

# SSH access for debugging — reads your local public key at build time.
# Supports id_ed25519, id_rsa, id_ecdsa (whichever exists).
ssh_pub_key =
  ~w(id_ed25519 id_rsa id_ecdsa)
  |> Enum.map(&Path.join([System.user_home!(), ".ssh", &1 <> ".pub"]))
  |> Enum.find_value(fn path ->
    case File.read(path) do
      {:ok, key} -> String.trim(key)
      _ -> nil
    end
  end)

if ssh_pub_key do
  config :nerves_ssh, authorized_keys: [ssh_pub_key]
else
  Mix.shell().info("Warning: no SSH public key found — nerves_ssh will be disabled")
  config :nerves_ssh, authorized_keys: []
end

# Display settings tuned for the Pi Zero 2 W (BCM2710A1) + SEENGREAT HAT +
# 64×64 1/32-scan HUB75 panel.
#
# These values were determined by live testing on the physical hardware,
# measuring the actual refresh rate via the hzeller library's show_refresh_rate
# diagnostic. The winning combination achieves 73.4 Hz with no visible flicker.
#
# slowdown_gpio: 1 — trying 1 instead of 2. The Pi Zero 2 W runs at 1 GHz
#   while the Pi 3 runs at 1.4 GHz, so the Zero 2 W may not need as much
#   slowdown to stay within the panel's shift-register timing budget.
#
# pwm_bits: 7 — reduced from default 11 (24-bit color) to 7 (~21-bit).
#   This cuts the number of time slots per row from 2048 to 128, dramatically
#   increasing refresh rate. The color depth reduction is imperceptible for
#   text, icons, and solid-color flight tracker UI.
#
# pwm_lsb_nanoseconds: 50 — reduced from default 130. Makes each PWM time
#   slot 2.6× shorter. Combined with pwm_bits=7 this is the primary driver
#   of the refresh rate improvement.
#
# pwm_dither_bits: 0 — temporal dithering disabled. Even with a high
#   refresh rate, dithering causes a slight visual shimmer on dim pixels
#   (like the divider line). The color depth loss is imperceptible for
#   this text/icon UI. Keeping it at 0 gives the cleanest display.
#
# show_refresh_rate: false — permanently disabled. The redirect.go safety net
#   sends printf() output to /dev/null so the Hz value is unreadable anyway,
#   and the printf() adds unnecessary overhead (float formatting + stdio mutex
#   + write syscall) on every frame of the real-time refresh thread.
#
# limit_refresh_hz: 0 — no cap; let the library run as fast as it can.
#   Testing showed uncapped refresh works better than a fixed ceiling.
config :aerovision, :display,
  rows: 64,
  cols: 64,
  chain_length: 1,
  parallel: 1,
  gpio_mapping: "regular",
  brightness: 80,
  slowdown_gpio: 1,
  limit_refresh_hz: 0,
  pwm_bits: 7,
  pwm_lsb_nanoseconds: 50,
  pwm_dither_bits: 0,
  show_refresh_rate: false
