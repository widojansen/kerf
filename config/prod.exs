import Config

config :exclaw, ExClaw.Repo,
  database: "priv/exclaw_prod.db"

config :exclaw, ExClaw.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: {:system, "SECRET_KEY_BASE"}

config :logger, level: :info
