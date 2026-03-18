import Config

dot_env_path = Path.join(File.cwd!(), ".env")
# ---------------------------------------------------------------------------
# Build-time .env injection
#
# Read the .env file at build time and bake the values into the firmware as
# application config. Config.Store reads these at startup via
# Application.get_env(:aerovision, :env_seeds) — no file I/O needed on device.
#
# Values are only used to seed blank settings; anything already saved through
# the UI takes precedence.
# ---------------------------------------------------------------------------
dot_env_raw =
  if File.exists?(dot_env_path) do
    dot_env_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      if line == "" or String.starts_with?(line, "#") or not String.contains?(line, "=") do
        acc
      else
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

        if key != "" and value != "", do: Map.put(acc, key, value), else: acc
      end
    end)
  else
    %{}
  end

e = fn key -> Map.get(dot_env_raw, key) end

# Phoenix config
config :aerovision, AeroVisionWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AeroVisionWeb.ErrorHTML, json: AeroVisionWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AeroVision.PubSub,
  live_view: [signing_salt: "aerovision_salt"]

config :aerovision, :display,
  rows: 64,
  cols: 64,
  chain_length: 1,
  parallel: 1,
  gpio_mapping: "regular",
  brightness: 80,
  slowdown_gpio: 1

config :aerovision, :env_seeds, %{
  skylink_api_key: e.("SKYLINK_API_KEY"),
  opensky_client_id: e.("OPENSKY_CLIENT_ID"),
  opensky_client_secret: e.("OPENSKY_CLIENT_SECRET"),
  wifi_ssid: e.("WIFI_SSID"),
  wifi_password: e.("WIFI_PASSWORD"),
  location_lat: e.("LOCATION_LAT"),
  location_lon: e.("LOCATION_LON"),
  radius_km: e.("RADIUS_KM"),
  radius_mi: e.("RADIUS_MI"),
  display_brightness: e.("DISPLAY_BRIGHTNESS"),
  display_cycle_seconds: e.("DISPLAY_CYCLE_SECONDS"),
  display_mode: e.("DISPLAY_MODE"),
  units: e.("UNITS"),
  tracked_flights: e.("TRACKED_FLIGHTS"),
  airline_filters: e.("AIRLINE_FILTERS"),
  airport_filters: e.("AIRPORT_FILTERS"),
  timezone: e.("TIMEZONE")
}

config :aerovision, :opensky,
  base_url: "https://opensky-network.org/api",
  token_url: "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"

config :aerovision, :skylink,
  base_url: "https://skylink-api.p.rapidapi.com",
  host: "skylink-api.p.rapidapi.com"

config :aerovision, target: Mix.target()

config :elixir, time_zone_database: Zoneinfo.TimeZoneDatabase

config :esbuild,
  version: "0.25.4",
  aerovision: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  aerovision: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

import_config "#{Mix.target()}.exs"
import_config "#{config_env()}.exs"
