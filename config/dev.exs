import Config

config :exclaw, Kerf.Repo,
  database: "exclaw_dev",
  hostname: "localhost",
  port: 5432,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :exclaw, Kerf.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it"

config :exclaw, Kerf.Telemetry.Logger,
  ch_opts: nil

config :logger, level: :debug
