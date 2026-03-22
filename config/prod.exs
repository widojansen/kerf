import Config

config :exclaw, ExClaw.Repo,
  database: "exclaw_prod",
  hostname: "localhost",
  port: 5432,
  pool_size: 10

config :exclaw, ExClaw.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: {:system, "SECRET_KEY_BASE"}

config :logger, level: :info
