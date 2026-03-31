import Config

config :exclaw, ExClaw.Repo,
  database: "exclaw_test",
  hostname: "localhost",
  port: 5432,
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

config :exclaw, ExClaw.Container.Manager,
  workspaces_dir: "priv/workspaces/test",
  exec_timeout: 5_000

config :exclaw, ExClaw.Tools.WebFetch,
  timeout: 5_000,
  max_content_chars: 10_000

config :exclaw, ExClaw.Tools.WebSearch,
  searxng_url: "http://localhost:8080",
  timeout: 5_000

config :exclaw, ExClaw.Memory.Embedder,
  enabled: false

config :exclaw, ExClaw.Channels.WhatsApp,
  enabled: false

config :exclaw, ExClaw.CredentialVault,
  enabled: false

config :exclaw, ExClaw.Workflow.ApprovalGate,
  enabled: false

config :exclaw, ExClaw.Telemetry.Logger,
  enabled: false,
  ch_opts: nil

config :logger, level: :warning
