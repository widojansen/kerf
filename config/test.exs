import Config

config :exclaw, ExClaw.Repo,
  database: "priv/exclaw_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

config :exclaw, ExClaw.LLM.Provider,
  api_key: "test-key-not-real",
  adapter: {Req.Test, ExClaw.LLM.Provider}

config :exclaw, ExClaw.LLM.RateLimiter,
  max_requests_per_minute: 1000,
  max_tokens_per_minute: 1_000_000

config :logger, level: :warning
