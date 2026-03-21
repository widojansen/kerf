import Config

# ---------------------------------------------------------------------------
# Runtime configuration -- evaluated at startup, not compile time.
# Sensitive values and environment-specific overrides go here.
# ---------------------------------------------------------------------------

# LLM backend selection.
# Set LLM_BACKEND=ollama in environment to use local Ollama instead of Anthropic.
case System.get_env("LLM_BACKEND", "anthropic") do
  "ollama" ->
    config :exclaw, :llm_backend, :ollama

    config :exclaw, ExClaw.LLM.OllamaProvider,
      base_url: System.get_env("OLLAMA_URL", "http://localhost:11434"),
      default_model: System.get_env("OLLAMA_MODEL", "qwen3:8b"),
      default_max_tokens: 8192

    config :exclaw, ExClaw.LLM.RateLimiter,
      # Ollama is local -- no hard rate limits needed
      max_requests_per_minute: 1000,
      max_tokens_per_minute: 10_000_000

  _ ->
    # Anthropic (default)
    config :exclaw, :llm_backend, :anthropic

    if api_key = System.get_env("ANTHROPIC_API_KEY") do
      config :exclaw, ExClaw.LLM.Provider, api_key: api_key
    end
end

# Dashboard secret key base (required in prod).
if secret = System.get_env("SECRET_KEY_BASE") do
  config :exclaw, ExClaw.Dashboard.Endpoint, secret_key_base: secret
end

# CLI group and model overrides.
if model = System.get_env("EXCLAW_MODEL") do
  config :exclaw, ExClaw.Channels.CLI, model: model
end
