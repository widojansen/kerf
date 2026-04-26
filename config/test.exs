import Config

config :kerf, Kerf.Repo,
  database: "exclaw_test",
  hostname: "localhost",
  port: 5432,
  pool: Ecto.Adapters.SQL.Sandbox

config :kerf, Kerf.LLM.Provider,
  api_key: "test-key-not-real",
  adapter: {Req.Test, Kerf.LLM.Provider}

config :kerf, Kerf.LLM.RateLimiter,
  max_requests_per_minute: 1000,
  max_tokens_per_minute: 1_000_000

config :kerf, Kerf.Memory.Store,
  data_dir: "priv/data/test"

config :kerf, Kerf.Channels.CLI,
  group_id: "cli_test",
  base_prompt: "You are a test assistant.",
  model: "claude-sonnet-4-20250514"

config :kerf, Kerf.Scheduler,
  provider: Kerf.LLM.Provider,
  model: "claude-sonnet-4-20250514"

config :kerf, Kerf.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it"

config :kerf, Kerf.Container.Manager,
  workspaces_dir: "priv/workspaces/test",
  exec_timeout: 5_000

config :kerf, Kerf.Tools.WebFetch,
  timeout: 5_000,
  max_content_chars: 10_000

config :kerf, Kerf.Tools.WebSearch,
  searxng_url: "http://localhost:8080",
  timeout: 5_000

config :kerf, Kerf.Memory.Embedder,
  enabled: false

config :kerf, Kerf.Channels.WhatsApp,
  enabled: false

config :kerf, Kerf.CredentialVault,
  enabled: false

config :kerf, Kerf.Workflow.ApprovalGate,
  enabled: false

config :kerf, Kerf.Telemetry.Logger,
  enabled: false,
  ch_opts: nil

config :logger, level: :warning
