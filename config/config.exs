import Config

config :aerovision, target: Mix.target()

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

config :aerovision, :opensky,
  base_url: "https://opensky-network.org/api",
  token_url:
    "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"

config :aerovision, :aeroapi, base_url: "https://aeroapi.flightaware.com/aeroapi"

config :aerovision, :display,
  rows: 64,
  cols: 64,
  chain_length: 1,
  parallel: 1,
  gpio_mapping: "regular",
  brightness: 80,
  slowdown_gpio: 1

import_config "#{config_env()}.exs"
import_config "#{Mix.target()}.exs"
