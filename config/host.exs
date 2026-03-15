import Config

config :aerovision, AeroVisionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  server: true,
  secret_key_base: "host_dev_secret_key_that_is_at_least_64_bytes_long_for_testing_only"
