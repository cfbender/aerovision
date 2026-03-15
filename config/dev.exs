import Config

config :aerovision, AeroVisionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_purposes_only",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:aerovision, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:aerovision, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/aerovision_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix, :plug_init_mode, :runtime

config :aerovision, dev_mode: true
