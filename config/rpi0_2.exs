import Config

config :logger, backends: [RingLogger]

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

# Configure mDNS
config :mdns_lite,
  hosts: [:hostname, "aerovision"],
  ttl: 120,
  services: [
    %{
      protocol: "http",
      transport: "tcp",
      port: 80
    }
  ]

# VintageNet default config — will be overridden by Network.Manager
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :nerves_time, :servers, [
  "0.pool.ntp.org",
  "1.pool.ntp.org",
  "2.pool.ntp.org",
  "3.pool.ntp.org"
]

# Disable unnecessary kernel features
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
