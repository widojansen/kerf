import Config

config :exclaw, ecto_repos: [ExClaw.Repo]

config :exclaw, ExClaw.Repo,
  database: "priv/exclaw_#{config_env()}.db"

config :exclaw, ExClaw.LLM.Provider,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  base_url: "https://api.anthropic.com/v1",
  anthropic_version: "2023-06-01",
  default_model: "claude-sonnet-4-20250514",
  default_max_tokens: 8192

config :exclaw, ExClaw.LLM.RateLimiter,
  max_requests_per_minute: 50,
  max_tokens_per_minute: 40_000

config :exclaw, ExClaw.Memory.Store,
  data_dir: "priv/data/#{config_env()}"

config :exclaw, ExClaw.Channels.CLI,
  group_id: "cli",
  base_prompt: "You are ExClaw, a personal AI assistant running in a terminal. Be concise and helpful.",
  model: "claude-sonnet-4-20250514"

config :exclaw, ExClaw.Scheduler,
  provider: ExClaw.LLM.Provider,
  model: "claude-sonnet-4-20250514"

config :exclaw, ExClaw.Dashboard.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: ExClaw.PubSub,
  live_view: [signing_salt: "exclaw_lv_salt"],
  render_errors: [formats: [html: ExClaw.Dashboard.ErrorHTML]]

config :exclaw, ExClaw.Dashboard.EventLog,
  max_size: 500

config :exclaw, ExClaw.Telemetry.Logger,
  enabled: true,
  flush_interval_ms: 5_000,
  max_buffer_size: 100,
  fallback_dir: "priv/telemetry_fallback"

import_config "#{config_env()}.exs"
