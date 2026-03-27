import Config

# ---------------------------------------------------------------------------
# Runtime configuration -- evaluated at startup, not compile time.
# ---------------------------------------------------------------------------

# LLM_BACKEND selects the local inference engine:
#   "vllm"   -> VLLMProvider (OpenAI-compatible, production throughput)
#   "ollama" -> OllamaProvider (legacy, single-user convenience)
#   unset    -> Anthropic-only mode
#
# vLLM uses NVFP4-quantized HuggingFace models (e.g. nvidia/Qwen3-32B-NVFP4)
# served via /v1/chat/completions on port 8000.
# Ollama uses GGUF models served via /api/chat on port 11434.

llm_backend = System.get_env("LLM_BACKEND")

if llm_backend == "vllm" do
  vllm_url = System.get_env("VLLM_URL", "http://localhost:8000")

  config :exclaw, ExClaw.LLM.VLLMProvider,
    name: ExClaw.LLM.VLLMProvider,
    base_url: vllm_url,
    default_model: System.get_env("VLLM_MODEL", "nvidia/Qwen3-32B-NVFP4"),
    default_max_tokens: 8192
end

if llm_backend == "ollama" do
  ollama_url = System.get_env("OLLAMA_URL", "http://localhost:11434")

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
# Examples:
#   EXCLAW_DEFAULT_MODEL=nvidia/Qwen3-32B-NVFP4  (vLLM)
#   EXCLAW_DEFAULT_MODEL=qwen3:8b                 (Ollama)
#   EXCLAW_DEFAULT_MODEL=claude-sonnet-4-6         (Anthropic)
if model = System.get_env("EXCLAW_DEFAULT_MODEL") do
  config :exclaw, ExClaw.Channels.CLI, model: model
  config :exclaw, ExClaw.Channels.Telegram, model: model
  config :exclaw, ExClaw.Scheduler, model: model
end


# Telegram Bot channel.
# TELEGRAM_BOT_TOKEN: token from @BotFather
# TELEGRAM_ALLOW_FROM: comma-separated Telegram user IDs (empty = allow all)
if telegram_token = System.get_env("TELEGRAM_BOT_TOKEN") do
  allow_from =
    case System.get_env("TELEGRAM_ALLOW_FROM", "") do
      "" -> []
      ids -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.to_integer/1)
    end

  config :exclaw, ExClaw.Channels.Telegram,
    enabled: true,
    token: telegram_token,
    allow_from: allow_from,
    poll_interval: 1_000,
    poll_timeout: 30
end

# Dashboard secret key base (required in prod).
if secret = System.get_env("SECRET_KEY_BASE") do
  config :exclaw, ExClaw.Dashboard.Endpoint, secret_key_base: secret
end
