import Config

config :exclaw, ecto_repos: [ExClaw.Repo]

config :exclaw, ExClaw.Repo,
  types: ExClaw.PostgrexTypes


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

config :exclaw, ExClaw.Memory.Embedder,
  base_url: "http://localhost:11434",
  model: "bge-m3"

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

config :exclaw, ExClaw.Container.Manager,
  workspaces_dir: "priv/workspaces",
  image: "exclaw-sandbox:latest",
  exec_timeout: 30_000,
  max_output_size: 102_400,
  container_opts: [
    read_only: true,
    network: "none",
    memory: "512m",
    cpus: "1",
    pids_limit: 256,
    cap_drop: ["ALL"],
    cap_add: ["CHOWN"],
    security_opt: ["no-new-privileges"],
    tmpfs: ["/tmp:rw,noexec,nosuid,size=256m"],
    user: "1000:1000"
  ]

config :exclaw, ExClaw.Tools.WebFetch,
  timeout: 15_000,
  max_content_chars: 50_000,
  user_agent: "ExClaw/0.1"

config :exclaw, ExClaw.Tools.WebSearch,
  searxng_url: "http://localhost:8080",
  timeout: 10_000

config :exclaw, ExClaw.Channels.Telegram,
  enabled: false,
  model: "claude-sonnet-4-20250514",
  base_prompt: "You are Tina, a personal AI assistant on Telegram, powered by ExClaw. Be concise and helpful. Keep responses under 4000 characters."

config :exclaw, ExClaw.Channels.WhatsApp,
  enabled: false,
  bridge_dir: "whatsapp-bridge",
  auth_dir: "priv/whatsapp_auth",
  node_path: "node",
  group_id_prefix: "wa",
  mention_required_in_groups: true,
  model: "claude-sonnet-4-20250514",
  base_prompt: "You are ExClaw, a personal AI assistant on WhatsApp. Be concise and helpful. Keep responses under 4000 characters."

config :exclaw, ExClaw.Telemetry.Logger,
  enabled: true,
  flush_interval_ms: 5_000,
  max_buffer_size: 100,
  fallback_dir: "priv/telemetry_fallback"

config :exclaw, ExClaw.StructuredOutput,
  default_max_retries: 2,
  default_temperature: 0.1,
  register_builtins: true

config :exclaw, ExClaw.Monitor.ProcessHealth,
  interval_ms: 30_000,
  queue_high_threshold: 100,
  memory_high_threshold_mb: 256,
  watched: [
    ExClaw.Channels.Telegram,
    ExClaw.LLM.ModelRouter,
    ExClaw.Scheduler.Scheduler,
    ExClaw.Agent.Supervisor
  ]

config :exclaw, ExClaw.Monitor.Alerting,
  debounce_window_ms: 300_000

import_config "#{config_env()}.exs"
