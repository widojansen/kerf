import Config

config :exclaw, ExClaw.Repo,
  database: "priv/exclaw_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning
