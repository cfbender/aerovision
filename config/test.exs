import Config

config :aerovision, AeroVisionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only",
  server: false

# Override the target to :test so the application supervisor only starts the
# bare minimum (PubSub, Config.Store, Telemetry). Tests manage flight pipeline
# processes themselves via start_supervised!.
config :aerovision, target: :test

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
