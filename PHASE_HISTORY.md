# ExClaw — Phase History & Design Decisions

> Reference document for phase-by-phase build history. For module contracts (public APIs), see `CLAUDE.md`.
> For the forward-looking roadmap (Phases A–I), see `ARCHITECTURE_PERSONAL_INTELLIGENCE.md`.

## Phase 1: Security Layer (61 tests)

Pure-function security checks wrapped in GenServers for supervision.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Security.FileGuard` | `lib/exclaw/security/file_guard.ex` | 15 |
| `ExClaw.Security.ShellSandbox` | `lib/exclaw/security/shell_sandbox.ex` | 27 |
| `ExClaw.Security.PromptGuard` | `lib/exclaw/security/prompt_guard.ex` | 19 |
| `ExClaw.Security.Supervisor` | `lib/exclaw/security/supervisor.ex` | — |

## Phase 2: LLM Providers (52 tests)

Multi-backend LLM: Anthropic, vLLM, Ollama with model-based routing.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.LLM.RateLimiter` | `lib/exclaw/llm/rate_limiter.ex` | 9 |
| `ExClaw.LLM.Provider` | `lib/exclaw/llm/provider.ex` | 17 |
| `ExClaw.LLM.VLLMProvider` | `lib/exclaw/llm/vllm_provider.ex` | 9 |
| `ExClaw.LLM.OllamaProvider` | `lib/exclaw/llm/ollama_provider.ex` | 7 |
| `ExClaw.LLM.ModelRouter` | `lib/exclaw/llm/model_router.ex` | 8 |
| `ExClaw.LLM.Supervisor` | `lib/exclaw/llm/supervisor.ex` | 2 |

**Key design decisions:**
- `Req` with adapter injection for testability (no Mox needed, no real HTTP in tests)
- `Provider` is a GenServer holding a pre-configured `Req` client; `complete/4` is a `GenServer.call`
- Parses both `:text` and `:tool_use` response types from Anthropic content blocks
- Rate limiter checks budget before each call, records usage (input+output tokens) after
- API key resolved from env var via `{:system, "ANTHROPIC_API_KEY"}` config pattern
- All errors return `{:error, reason}` — GenServer never crashes on API/network errors
- Non-streaming (synchronous request/response); streaming deferred to future phase
- **VLLMProvider**: OpenAI-compatible `/v1/chat/completions` endpoint for vLLM/SGLang; converts Anthropic tool format to OpenAI format transparently; 120s `receive_timeout` for thinking models
- **OllamaProvider**: Ollama `/api/chat` endpoint for local inference; same response shape as VLLMProvider
- **ModelRouter**: GenServer with regex-based routing rules; first match wins; `LLM_BACKEND` env var configures which backends start and what routes are registered; `claude-*` → Anthropic, `nvidia/*`/`qwen*`/`deepseek*` → vLLM or Ollama
- All three providers expose identical `complete/4` API and return the same response shape

## Phase 3: Agent Session (23 tests)

Core agent loop: receives messages, calls LLM, executes tools with security checks, loops until text response.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Agent.Session` | `lib/exclaw/agent/session.ex` | 19 (+4 added in Phase 7) |
| `ExClaw.Agent.Supervisor` | `lib/exclaw/agent/supervisor.ex` | 4 |

**Key design decisions:**
- `Session` is a GenServer per chat group; registered via `{:via, Registry, {registry, group_id}}`
- Agent loop: call Provider → `:text` returns response, `:tool_use` runs security checks + executor then recurses
- Tool executor injection: accepts `:tool_executor` function `fn(name, input) -> {:ok, result} | {:error, reason}`, default returns "tool not available"
- Security denials returned to LLM as tool_result strings (`"Security denied: reason"`), not errors — lets LLM adjust approach
- Anthropic string-keyed tool inputs atomized via `String.to_existing_atom/1` before security checks; atomization failure explicitly denies the tool call (prevents security bypass)
- `restart: :temporary` — sessions don't auto-restart (stateful conversation history can't be reconstructed)
- Supervisor uses `find_or_start_session` with Registry lookup, handles `{:already_started, pid}` race, retries on stale pid (`:noproc`)
- Tool executor exceptions are caught and returned as tool result strings — GenServer never crashes on tool errors
- Max iteration limit (default 25) prevents infinite tool loops
- Idle timeout with hibernate support (default 30 min)
- Agent loop runs synchronously in `handle_call` — acceptable for CLI, may need async pattern for concurrent channels

## Phase 4: Memory Store (34 tests)

Persistent memory: structured facts (PostgreSQL), per-group MEMORY.md (filesystem), and message history (PostgreSQL).

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Memory.Fact` | `lib/exclaw/memory/fact.ex` | Schema |
| `ExClaw.Memory.Message` | `lib/exclaw/memory/message.ex` | Schema |
| `ExClaw.Memory.Store` | `lib/exclaw/memory/store.ex` | 31 |
| `ExClaw.Memory.Supervisor` | `lib/exclaw/memory/supervisor.ex` | 3 |

**Key design decisions:**
- `Store` is a GenServer holding `%{data_dir: path, repo: module}` — minimal config-only state
- Three storage types: facts (PostgreSQL upsert on group_id+key), MEMORY.md (filesystem), messages (PostgreSQL)
- All operations synchronous via `handle_call` — same pattern as `LLM.Provider`
- ILIKE search for case-insensitive matching (PostgreSQL)
- Group ID sanitized for filesystem paths: non-alphanumeric chars replaced with `_`
- Path traversal prevention: `data_dir` expanded to absolute on init, resolved paths verified to stay inside
- All errors return `{:error, reason}` — GenServer never crashes on DB/filesystem errors
- Ecto SQL Sandbox with `allow/3` for test isolation — GenServer process gets its own connection
- Messages retrieved via desc+reverse pattern for efficient "last N" queries in chronological order

## Phase 5: CLI Channel (18 tests)

Terminal REPL wiring everything together into the minimum viable assistant.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Channels.CLI` | `lib/exclaw/channels/cli.ex` | 18 |
| `Mix.Tasks.Exclaw.Cli` | `lib/mix/tasks/exclaw.cli.ex` | — |

**Key design decisions:**
- Simple module with `start/0`, NOT a GenServer — the CLI is a synchronous blocking REPL
- Core logic extracted into testable public functions (`exit_command?`, `build_system_prompt`, `process_input`, `persist_exchange`)
- Dependency injection via opts — all dependencies injectable for testing
- System prompt built once at start — MEMORY.md loaded at REPL start, not per-message

## Phase 6: Scheduler (28 tests)

Cron-like recurring task execution using OTP-native `Process.send_after`.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Scheduler.ScheduledTask` | `lib/exclaw/scheduler/scheduled_task.ex` | Schema |
| `ExClaw.Scheduler.TaskRunLog` | `lib/exclaw/scheduler/task_run_log.ex` | Schema |
| `ExClaw.Scheduler.Scheduler` | `lib/exclaw/scheduler/scheduler.ex` | 13 |
| `ExClaw.Scheduler.Supervisor` | `lib/exclaw/scheduler/supervisor.ex` | 3 |

**Key design decisions:**
- Four schedule types: `cron`, `interval`, `once`, `at` (ISO-8601)
- Context modes: `"group"` reuses existing Agent.Session, `"isolated"` creates fresh session per run
- `rest_for_one` supervisor: Task.Supervisor + Scheduler (timer refs invalidated on restart)
- One-shot tasks (`once`/`at`) auto-complete after execution

## Phase 7: Dashboard (22 tests)

Localhost-only Phoenix LiveView web UI for observability.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Dashboard.EventLog` | `lib/exclaw/dashboard/event_log.ex` | 10 |
| `ExClaw.Dashboard.Live.DashboardLive` | `lib/exclaw/dashboard/live/dashboard_live.ex` | 12 |

**Key design decisions:**
- EventLog: ETS `:ordered_set` ring buffer (max 500 entries), fire-and-forget `cast` for production, `call` for testing
- PubSub broadcast on every log for real-time LiveView push
- Single LiveView with tab-based navigation (Overview, Memory, Security, LLM, System, Scheduler)
- Minimal inline CSS, no Tailwind, Bandit adapter, localhost-only binding

## Phase 8: Telemetry (23 tests)

Comprehensive fire-and-forget telemetry with ClickHouse batch writes and JSONL fallback.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Telemetry` | `lib/exclaw/telemetry/telemetry.ex` | 9 |
| `ExClaw.Telemetry.Logger` | `lib/exclaw/telemetry/logger.ex` | 11 |
| `ExClaw.Telemetry.Supervisor` | `lib/exclaw/telemetry/supervisor.ex` | 3 |

**Key design decisions:**
- `Logger` is a GenServer: buffers events, flushes to ClickHouse via `ch` library or JSONL fallback
- `emit/3` uses `GenServer.cast` inside `try/catch :exit` — never blocks, never raises
- `enabled: false` in test config — existing tests completely unaffected
- 9 event categories: `llm_call`, `llm_error`, `security_check`, `tool_execution`, `session_lifecycle`, `message_round_trip`, `memory_operation`, `scheduler_event`, `channel_event`
- ClickHouse DDL in `priv/clickhouse/create_tables.sql`, docker-compose in `docker-compose.clickhouse.yml`

### ClickHouse Setup

```bash
docker compose -f docker-compose.clickhouse.yml up -d
# Query: clickhouse-client -q "SELECT * FROM exclaw_dev.exclaw_events"
```

## Phase 9: Container Sandboxing + Tools (30 unit + 12 integration tests)

Docker container-per-group sandboxing with built-in tools: `shell_exec`, `file_read`, `file_write`.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Container.Manager` | `lib/exclaw/container/manager.ex` | 15 |
| `ExClaw.Container.Supervisor` | `lib/exclaw/container/supervisor.ex` | 3 |
| `ExClaw.Tools.FileOps` | `lib/exclaw/tools/file_ops.ex` | 11 |
| `ExClaw.Tools.Shell` | `lib/exclaw/tools/shell.ex` | 4 |
| `ExClaw.Tools.Dispatcher` | `lib/exclaw/tools/dispatcher.ex` | 21 |
| Integration tests | `test/container/integration/` | 12 (tagged `:docker`) |

**Key design decisions:**
- OpenClaw-style persistent containers (`sleep infinity` + `docker exec`) — no startup overhead per command
- Docker adapter injection for testability
- Docker security: `--read-only`, `--cap-drop ALL --cap-add CHOWN`, `--security-opt no-new-privileges`, `--network none`, `--memory 512m`, `--cpus 1`, `--pids-limit 256`
- File operations use host filesystem directly via bind-mounted workspace — no Docker needed
- Path traversal prevention: resolved paths checked against workspace boundary
- Sandbox image: `debian:bookworm-slim` with bash, curl, jq, python3, git

## Phase 10: WhatsApp Channel (24 tests)

WhatsApp channel via Node.js Baileys sidecar over Erlang Port (stdin/stdout JSON lines).

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Channels.WhatsApp` | `lib/exclaw/channels/whatsapp.ex` | 22 |
| `ExClaw.Channels.WhatsApp.Supervisor` | `lib/exclaw/channels/whatsapp/supervisor.ex` | 2 |

**Key design decisions:**
- Node.js sidecar running `@whiskeysockets/baileys` 6.7.21 (stable)
- Communication via Erlang Port + newline-delimited JSON (not HTTP) — OTP-native lifecycle
- `port_opener` injection for testability
- Conditional startup: `enabled: false` by default
- `restart: :transient` — restart on crash, not on normal stop (logged_out)
- Setup: `cd whatsapp-bridge && npm install`, then enable in config and start ExClaw

## Phase 11: Tool Registry + WebFetch + WebSearch (87 tests)

Dynamic tool registration, URL fetching with SSRF protection, web search via SearXNG.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Tools.Registry` | `lib/exclaw/tools/registry.ex` | 16 |
| `ExClaw.Tools.Registrations` | `lib/exclaw/tools/registrations.ex` | — |
| `ExClaw.Tools.Dispatcher` | `lib/exclaw/tools/dispatcher.ex` | 21 |
| `ExClaw.Tools.WebFetch` | `lib/exclaw/tools/web_fetch.ex` | 26 |
| `ExClaw.Tools.WebSearch` | `lib/exclaw/tools/web_search.ex` | 24 |

**Key design decisions:**
- **ETS-backed Registry**: GenServer serializes writes, ETS `:public` `:named_table` for lock-free reads
- **Dispatcher refactored**: pattern matching replaced with `Registry.get_tool` → `apply(mod, fun, [input, opts])`
- **WebFetch SSRF protection**: DNS resolution via `:inet.getaddr/2`, blocks private IP ranges
- **WebSearch via SearXNG**: self-hosted Docker meta-search engine with JSON API
- HTTP client injection via `:http_client` opt for testability (same pattern as LLM.Provider)

### SearXNG Setup

```bash
docker compose -f docker-compose.searxng.yml up -d
# Verify: curl "http://localhost:8080/search?q=test&format=json"
```

Config: `searxng/settings.yml`, `config :exclaw, ExClaw.Tools.WebSearch, searxng_url: "http://localhost:8080"`

## Phase 12: Telegram Channel (20 tests)

Telegram bot with long polling, authorized user filtering, `<think>` tag stripping.

| Module | File | Tests |
|--------|------|-------|
| `ExClaw.Channels.Telegram` | `lib/exclaw/channels/telegram.ex` | 18 |
| `ExClaw.Channels.Telegram.Supervisor` | `lib/exclaw/channels/telegram/supervisor.ex` | 2 |

**Key design decisions:**
- Long-polling Telegram Bot API with exponential backoff on errors
- Authorization by user ID whitelist (`allow_from: []` allows all)
- `<think>...</think>` tag stripping from thinking model responses (vLLM/Ollama)
- System prompt with identity ("Tina") + group memory integration (same pattern as WhatsApp)
- Routes through `ModelRouter` — supports all backends
- Conditional startup: requires `TELEGRAM_BOT_TOKEN` env var

## Phase 13: SQLite → PostgreSQL Migration

Full migration from SQLite to PostgreSQL with pgvector and AGE extensions.

- `mix.exs` — replaced `ecto_sqlite3` with `ecto_sql` + `postgrex` + `pgvector`
- `lib/exclaw/repo.ex` — adapter changed to `Ecto.Adapters.Postgres`
- `lib/exclaw/postgrex_types.ex` — Postgrex types with pgvector extensions
- `lib/exclaw/memory/store.ex` — `LIKE` → `ILIKE` for case-insensitive search
- New migrations: `CREATE EXTENSION vector` + `CREATE EXTENSION age`, embedding columns (vector 1024) with HNSW indexes
