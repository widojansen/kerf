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

import_config "#{config_env()}.exs"
