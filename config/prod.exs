import Config

config :aerovision, AeroVisionWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 80],
  check_origin: false,
  server: true,
  secret_key_base: "production_secret_that_should_be_generated_with_mix_phx_gen_secret"
