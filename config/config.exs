import Config

# Time zone database — :tz provides full IANA zone data so Oban.Plugins.Cron
# can resolve "Europe/Amsterdam" (DST included) at boot. Required by the
# email-digest cron (Step 13).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :kerf, ecto_repos: [Kerf.Repo]

config :kerf, Kerf.Repo,
  types: Kerf.PostgrexTypes


config :kerf, Kerf.LLM.Provider,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  base_url: "https://api.anthropic.com/v1",
  anthropic_version: "2023-06-01",
  default_model: "claude-sonnet-4-20250514",
  default_max_tokens: 8192

config :kerf, Kerf.LLM.RateLimiter,
  max_requests_per_minute: 50,
  max_tokens_per_minute: 40_000

config :kerf, Kerf.Memory.Store,
  data_dir: "priv/data/#{config_env()}"

config :kerf, Kerf.Memory.Embedder,
  base_url: "http://localhost:11434",
  model: "bge-m3"

config :kerf, Kerf.Channels.CLI,
  group_id: "cli",
  base_prompt: "You are Kerf, a personal AI assistant running in a terminal. Be concise and helpful.",
  model: "claude-sonnet-4-20250514"

config :kerf, Kerf.Scheduler,
  provider: Kerf.LLM.Provider,
  model: "claude-sonnet-4-20250514"

config :kerf, Kerf.Dashboard.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Kerf.PubSub,
  # Salt indexes data at rest (signed cookies). Treat as opaque-internal data identity, not code identity.
  live_view: [signing_salt: "exclaw_lv_salt"],
  render_errors: [formats: [html: Kerf.Dashboard.ErrorHTML]]

config :kerf, Kerf.Dashboard.EventLog,
  max_size: 500

config :kerf, Kerf.Container.Manager,
  workspaces_dir: "priv/workspaces",
  image: "kerf-sandbox:latest",
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

config :kerf, Kerf.Tools.WebFetch,
  timeout: 15_000,
  max_content_chars: 50_000,
  user_agent: "Kerf/0.1"

config :kerf, Kerf.Tools.WebSearch,
  searxng_url: "http://localhost:8080",
  timeout: 10_000

config :kerf, Kerf.Channels.Telegram,
  enabled: false,
  model: "claude-sonnet-4-20250514",
  base_prompt: "You are Tina, a personal AI assistant on Telegram, powered by Kerf. Be concise and helpful. Keep responses under 4000 characters."

config :kerf, Kerf.Channels.WhatsApp,
  enabled: false,
  bridge_dir: "whatsapp-bridge",
  auth_dir: "priv/whatsapp_auth",
  node_path: "node",
  group_id_prefix: "wa",
  mention_required_in_groups: true,
  model: "claude-sonnet-4-20250514",
  base_prompt: "You are Kerf, a personal AI assistant on WhatsApp. Be concise and helpful. Keep responses under 4000 characters."

config :kerf, Kerf.Telemetry.Logger,
  enabled: true,
  flush_interval_ms: 5_000,
  max_buffer_size: 100,
  fallback_dir: "priv/telemetry_fallback"

config :kerf, Kerf.StructuredOutput,
  default_max_retries: 2,
  default_temperature: 0.1,
  register_builtins: true

config :kerf, Kerf.Monitor.ProcessHealth,
  interval_ms: 30_000,
  queue_high_threshold: 100,
  memory_high_threshold_mb: 256,
  watched: [
    Kerf.Channels.Telegram,
    Kerf.LLM.ModelRouter,
    Kerf.Scheduler.Scheduler,
    Kerf.Agent.Supervisor
  ]

config :kerf, Kerf.Monitor.Alerting,
  debounce_window_ms: 300_000

# ---------------------------------------------------------------------------
# Oban — background job processing.
# Foundation for the email enrichment / routing workers (Email Triage
# Enrichment spec, Step 0c). Static across envs; test.exs overrides with
# `testing: :manual` so jobs don't auto-execute during the test suite.
# ---------------------------------------------------------------------------
config :kerf, Oban,
  repo: Kerf.Repo,
  queues: [
    email_enrichment: 2,
    email_routing: 4,
    email_digest: 1,
    monitoring: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600}
  ]

# Oban.Plugins.Cron is appended in runtime.exs — its crontab calls
# DigestCron.expression!() which references a project module not yet
# available at config.exs evaluation time.

import_config "#{config_env()}.exs"
