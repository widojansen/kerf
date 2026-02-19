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

config :exclaw, ExClaw.Memory.Store,
  data_dir: "priv/data/test"

config :exclaw, ExClaw.Channels.CLI,
  group_id: "cli_test",
  base_prompt: "You are a test assistant.",
  model: "claude-sonnet-4-20250514"

config :exclaw, ExClaw.Scheduler,
  provider: ExClaw.LLM.Provider,
  model: "claude-sonnet-4-20250514"

config :exclaw, ExClaw.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it"

config :logger, level: :warning
