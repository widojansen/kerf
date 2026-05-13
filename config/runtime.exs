import Config

# ---------------------------------------------------------------------------
# Runtime configuration -- evaluated at startup, not compile time.
# ---------------------------------------------------------------------------

# LLM_BACKEND selects the local inference engine:
#   "vllm"   -> VLLMProvider (OpenAI-compatible, production throughput)
#   "ollama" -> OllamaProvider (legacy, single-user convenience)
#   unset    -> Anthropic-only mode
#
# vLLM uses NVFP4-quantized HuggingFace models (e.g. Nemotron-Cascade-2-30B-A3B-NVFP4)
# served via /v1/chat/completions on port 8000.
# Ollama uses GGUF models served via /api/chat on port 11434.

llm_backend = System.get_env("LLM_BACKEND")

if llm_backend == "vllm" do
  vllm_url = System.get_env("VLLM_URL", "http://localhost:8000")

  config :kerf, Kerf.LLM.VLLMProvider,
    name: Kerf.LLM.VLLMProvider,
    base_url: vllm_url,
    default_model: System.get_env("VLLM_MODEL", "nemotron-cascade-2"),
    default_max_tokens: 8192
end

if llm_backend == "ollama" do
  ollama_url = System.get_env("OLLAMA_URL", "http://localhost:11434")

  config :kerf, Kerf.LLM.OllamaProvider,
    name: Kerf.LLM.OllamaProvider,
    base_url: ollama_url,
    default_model: System.get_env("OLLAMA_MODEL", "qwen3:8b"),
    default_max_tokens: 8192
end

# Embedding service -- defaults to Ollama on localhost:11434.
# Uses OpenAI-compatible /v1/embeddings endpoint (Ollama, TEI, vLLM all support this).
# EMBEDDING_URL: base URL of the embedding service
# EMBEDDING_MODEL: override model name (default: bge-m3)
#
# Default (Ollama, already installed):
#   ollama pull bge-m3
#
# Alternative (TEI, x86_64 only — no ARM64 images as of 2026-03):
#   docker run -p 8090:80 ghcr.io/huggingface/text-embeddings-inference:latest \
#     --model-id BAAI/bge-m3
#   Then set EMBEDDING_URL=http://localhost:8090
#
# Alternative (vLLM --task embed, GPU-accelerated):
#   vllm serve BAAI/bge-m3 --task embed --port 8001 \
#     --hf-overrides '{"architectures": ["BgeM3EmbeddingModel"]}'
#   Then set EMBEDDING_URL=http://localhost:8001
if embedding_url = System.get_env("EMBEDDING_URL") do
  config :kerf, Kerf.Memory.Embedder,
    base_url: embedding_url,
    model: System.get_env("EMBEDDING_MODEL", "bge-m3")
end

# Anthropic API key -- only needed for claude-* models.
if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :kerf, Kerf.LLM.Provider, api_key: api_key
end

# Default model for CLI and new Agent sessions.
# Examples:
#   KERF_DEFAULT_MODEL=nemotron-cascade-2       (vLLM)
#   KERF_DEFAULT_MODEL=qwen3:8b                 (Ollama)
#   KERF_DEFAULT_MODEL=claude-sonnet-4-6         (Anthropic)
if model = System.get_env("KERF_DEFAULT_MODEL") do
  config :kerf, Kerf.Channels.CLI, model: model
  config :kerf, Kerf.Channels.Telegram, model: model
  config :kerf, Kerf.Scheduler, model: model
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

  config :kerf, Kerf.Channels.Telegram,
    enabled: true,
    token: telegram_token,
    allow_from: allow_from,
    poll_interval: 1_000,
    poll_timeout: 30
end

# Dashboard secret key base (required in prod).
# Generate with: mix phx.gen.secret
if secret = System.get_env("SECRET_KEY_BASE") do
  config :kerf, Kerf.Dashboard.Endpoint, secret_key_base: secret

  # Credential Vault — uses SECRET_KEY_BASE for encryption at rest.
  config :kerf, Kerf.CredentialVault,
    enabled: true,
    encryption_key_base: secret
end

# ApprovalGate — Telegram-based human approval workflow.
# TELEGRAM_APPROVAL_CHAT_ID: override chat for approval messages (defaults to first TELEGRAM_ALLOW_FROM).
approval_chat_id =
  case System.get_env("TELEGRAM_APPROVAL_CHAT_ID") do
    nil ->
      case System.get_env("TELEGRAM_ALLOW_FROM", "") do
        "" -> nil
        ids -> ids |> String.split(",") |> List.first() |> String.trim() |> String.to_integer()
      end
    id -> String.to_integer(id)
  end

if approval_chat_id do
  config :kerf, Kerf.Workflow.ApprovalGate,
    enabled: true,
    default_timeout_ms: 300_000,
    default_chat_id: approval_chat_id
end

# ---------------------------------------------------------------------------
# Docker-aware overrides — only activate when env vars are set.
# Bare-metal deployments are unaffected (defaults come from prod.exs).
# ---------------------------------------------------------------------------

# Database — DATABASE_URL takes precedence, otherwise individual DB_* vars.
if config_env() == :prod do
  if database_url = System.get_env("DATABASE_URL") do
    config :kerf, Kerf.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  else
    db_overrides =
      [
        hostname: System.get_env("DB_HOST"),
        port: (if p = System.get_env("DB_PORT"), do: String.to_integer(p)),
        database: System.get_env("DB_NAME"),
        username: System.get_env("DB_USER"),
        password: System.get_env("DB_PASS")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if db_overrides != [] do
      config :kerf, Kerf.Repo, db_overrides
    end
  end
end

# Dashboard bind address — set DASHBOARD_IP=0.0.0.0 in Docker.
if dashboard_ip = System.get_env("DASHBOARD_IP") do
  parsed_ip =
    dashboard_ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()

  dashboard_port = String.to_integer(System.get_env("DASHBOARD_PORT", "4000"))
  config :kerf, Kerf.Dashboard.Endpoint, http: [ip: parsed_ip, port: dashboard_port]
end

# SearXNG URL override.
if searxng_url = System.get_env("SEARXNG_URL") do
  config :kerf, Kerf.Tools.WebSearch, searxng_url: searxng_url
end

# Data directory overrides (for Docker volume mounts).
if data_dir = System.get_env("KERF_DATA_DIR") do
  config :kerf, Kerf.Memory.Store, data_dir: data_dir
end

if workspaces_dir = System.get_env("KERF_WORKSPACES_DIR") do
  config :kerf, Kerf.Container.Manager, workspaces_dir: workspaces_dir
end

if fallback_dir = System.get_env("KERF_TELEMETRY_DIR") do
  config :kerf, Kerf.Telemetry.Logger, fallback_dir: fallback_dir
end

# ---------------------------------------------------------------------------
# Phase B: Knowledge Base Embedder + Email Triage
# ---------------------------------------------------------------------------

# KB Embedder — uses the same OpenAI-compatible /v1/embeddings endpoint.
# Can reuse EMBEDDING_URL or set a separate KB_EMBEDDING_URL.
kb_embedding_url = System.get_env("KB_EMBEDDING_URL") || System.get_env("EMBEDDING_URL")

if kb_embedding_url do
  config :kerf, Kerf.KnowledgeBase.Embedder,
    url: kb_embedding_url,
    model: System.get_env("KB_EMBEDDING_MODEL", "nomic-ai/nomic-embed-text-v1")
end

# Email Ingestor — polls Gmail for new emails.
# Requires Credential Vault with a "gmail_oauth" credential.
if System.get_env("EMAIL_TRIAGE_ENABLED") == "true" do
  config :kerf, Kerf.Ingestors.Email.EmailIngestor,
    enabled: true,
    poll_interval_ms: String.to_integer(System.get_env("EMAIL_POLL_INTERVAL_MS", "300000")),
    max_per_batch: 50,
    credential_name: System.get_env("GMAIL_CREDENTIAL_NAME", "gmail_oauth")

  config :kerf, Kerf.Agents.EmailTriage,
    enabled: true,
    interest_threshold: 0.5,
    high_priority_threshold: 4,
    classification_model: System.get_env("CLASSIFICATION_MODEL", "nemotron-cascade-2")
end

# ---------------------------------------------------------------------------
# Monitoring: Alert delivery via Telegram
# ---------------------------------------------------------------------------

alert_chat_id =
  System.get_env("TELEGRAM_ALERT_CHAT_ID") ||
    case System.get_env("TELEGRAM_ALLOW_FROM", "") do
      "" -> nil
      ids -> ids |> String.split(",") |> List.first() |> String.trim()
    end

if alert_chat_id do
  config :kerf, Kerf.Monitor.Alerting,
    telegram_chat_id: alert_chat_id
end

# ---------------------------------------------------------------------------
# Step 13: Email digest cron. Appended at runtime because DigestCron.expression!()
# requires the project module to be loaded (config.exs is evaluated before
# project compilation). Replaces the plugins list from config.exs — Elixir
# Config does shallow merge on the list value, so Pruner is restated here.
# ---------------------------------------------------------------------------
if config_env() != :test do
  config :kerf, Oban,
    plugins: [
      {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600},
      {Oban.Plugins.Cron,
       crontab: [
         {Kerf.Agents.EmailTriage.DigestCron.expression!(),
          Kerf.Agents.EmailTriage.DigestWorker}
       ],
       timezone: "Europe/Amsterdam"}
    ]
end

# Phoenix server — start endpoint in release mode.
if System.get_env("PHX_SERVER") do
  config :kerf, Kerf.Dashboard.Endpoint, server: true
end
