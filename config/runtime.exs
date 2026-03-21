import Config

# ---------------------------------------------------------------------------
# Runtime configuration -- evaluated at startup, not compile time.
# ---------------------------------------------------------------------------

# When LLM_BACKEND=ollama, OllamaProvider starts and ModelRouter routes
# local model names to it. Anthropic Provider is always started for
# claude-* models. Both can run simultaneously -- 128GB unified RAM on
# the Spark means qwen3:8b, qwen3:32b, deepseek-r1:32b can all be loaded.

ollama_url =
  if System.get_env("LLM_BACKEND") == "ollama" do
    System.get_env("OLLAMA_URL", "http://localhost:11434")
  end

if ollama_url do
  config :exclaw, ExClaw.LLM.OllamaProvider,
    name: ExClaw.LLM.OllamaProvider,
    base_url: ollama_url,
    default_model: System.get_env("OLLAMA_MODEL", "qwen3:8b"),
    default_max_tokens: 8192
end

# Anthropic API key -- only needed for claude-* models.
if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :exclaw, ExClaw.LLM.Provider, api_key: api_key
end

# Default model for CLI and new Agent sessions.
# Example: EXCLAW_DEFAULT_MODEL=qwen3:8b to use local inference by default.
if model = System.get_env("EXCLAW_DEFAULT_MODEL") do
  config :exclaw, ExClaw.Channels.CLI, model: model
  config :exclaw, ExClaw.Scheduler, model: model
end

# Dashboard secret key base (required in prod).
if secret = System.get_env("SECRET_KEY_BASE") do
  config :exclaw, ExClaw.Dashboard.Endpoint, secret_key_base: secret
end
