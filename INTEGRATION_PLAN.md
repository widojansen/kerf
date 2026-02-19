# ExClaw Integration Plan — izi_monitoring & tecdoc_importer

## Overview

ExClaw becomes a reusable Elixir library that provides AI agent capabilities to two existing
Phoenix/LiveView projects. Each project adds ExClaw as a dependency and defines its own
domain-specific tools, while ExClaw handles the LLM client, agent loop, security guards,
memory, and event logging.

---

## The Two Target Projects

### izi_monitoring

- **Stack:** Elixir 1.15, Phoenix 1.8, LiveView 1.1, PostgreSQL + ClickHouse (Pillar)
- **Purpose:** Real-time monitoring dashboard for a production Rails app (50 rps typical, spikes to 250 rps)
- **ClickHouse tables:** `request_monitoring`, `job_monitoring`, `log_services`
- **Metrics:** Throughput (count/min), latency percentiles (p50/p95/p99/max), trend comparison (current vs 5-min-ago vs 10-min-ago)
- **Existing LLM plans:** Dual-backend (Anthropic + Ollama), NL→SQL query generation, anomaly narration, root-cause analysis — designed but NOT yet implemented
- **Location:** `~/Projects/Orangestack/Izimotive/Gits/izi_monitoring`

### tecdoc_importer

- **Stack:** Elixir 1.17, Phoenix 1.7, LiveView 1.0, PostgreSQL
- **Purpose:** Automotive parts catalog — imports TecDoc TAF2.7 data (50+ tables), serves multi-language catalog UI with cross-reference lookups
- **Key context module:** `TecdocImporter.Catalog` (42KB, complex JOINs across vehicle→genart→brand→article relationships)
- **Features:** Vehicle search, brand search, cross-reference finder, hierarchical custom menus, admin UI
- **AI/ML integration:** None — pure data infrastructure
- **Location:** `~/Projects/Tecdoc/tecdoc_importer`

---

## Integration Architecture: ExClaw as Library Dependency

### Why Library (not Umbrella, not Copy)

| Approach | Pros | Cons |
|----------|------|------|
| **Library dep (chosen)** | Single source of truth, independent release cycles, clean dependency | Requires extracting ExClaw into library shape |
| Umbrella app | Shared compilation, single deploy | Couples unrelated domains, forces shared release cycle |
| Copy modules | Quick start | Drift between copies, triple maintenance burden |

### What ExClaw Provides (Reusable Core)

| Module | Capability | Used By |
|--------|-----------|---------|
| `ExClaw.LLM.Provider` | Anthropic API client (Req-based), configurable model/tokens | Both |
| `ExClaw.LLM.RateLimiter` | Sliding-window rate limiting (requests + tokens per minute) | Both |
| `ExClaw.Agent.Session` | Multi-turn tool-use loop (call LLM → execute tools → recurse until text response) | Both |
| `ExClaw.Agent.Supervisor` | DynamicSupervisor, find-or-start session by group_id | Both |
| `ExClaw.Security.FileGuard` | Path traversal, dotfile, workspace boundary checks | Both (if file tools exposed) |
| `ExClaw.Security.ShellSandbox` | Dangerous command blocking | Both (if shell tools exposed) |
| `ExClaw.Security.PromptGuard` | Prompt injection detection across all string values | Both |
| `ExClaw.Memory.Store` | Facts (SQLite/Ecto), MEMORY.md (filesystem), message history | Both |
| `ExClaw.Telemetry.Logger` (future) | Structured event logging to ClickHouse with batched async writes | Both |

### What Each Project Provides (Domain-Specific)

| Concern | izi_monitoring | tecdoc_importer |
|---------|---------------|-----------------|
| **Tools** | `query_clickhouse/1`, `detect_anomalies/1`, `correlate_tables/1`, `explain_pattern/1` | `search_vehicles/1`, `search_articles/1`, `find_cross_references/1`, `get_compatibility/1`, `get_article_detail/1` |
| **UI** | LiveView `ChatComponent`, `AnomalyAlert` (already designed) | New LiveView chat component for catalog assistant |
| **Channel** | LiveView channel (real-time dashboard) | LiveView channel (catalog search) |
| **ClickHouse** | Already connected (Pillar) — monitoring data source AND event logging target | New connection — event logging only |
| **System prompt** | Monitoring domain context, ClickHouse schema descriptions, anomaly thresholds | TecDoc domain context, catalog schema, parts terminology |

---

## izi_monitoring Integration Detail

### What ExClaw Replaces

The entire planned `Dashboard.LLM.*` module tree:

```
PLANNED (not yet built)              REPLACED BY
─────────────────────────           ──────────────
Dashboard.LLM.Client              → ExClaw.LLM.Provider
Dashboard.LLM.Backends.Anthropic  → ExClaw.LLM.Provider (Anthropic-native)
Dashboard.LLM.Backends.Ollama     → Future: ExClaw Ollama backend or keep separate
Dashboard.LLM.QueryGenerator      → Tool: generate_and_run_query (agent decides)
Dashboard.LLM.QueryValidator      → ExClaw.Security.PromptGuard + custom SQL validator tool
Dashboard.LLM.AnomalyNarrator     → Agent with anomaly context in system prompt
Dashboard.LLM.Summarizer          → Agent capability (no separate module needed)
Dashboard.LLM.SchemaContext        → System prompt injection (table schemas as context)
Dashboard.LLM.PromptTemplates     → System prompt for the agent session
```

### Agent Flow: Natural Language Monitoring

```
User (via LiveView chat): "Why is p99 latency spiking?"
    │
    ▼
ExClaw.Agent.Session (group_id: "dashboard_user_123")
    │
    ├─ LLM decides to call tool: query_clickhouse
    │   Input: {sql: "SELECT quantile(0.99)(processing_time) as p99,
    │            toStartOfMinute(timestamp) as minute
    │            FROM request_monitoring
    │            WHERE timestamp > now() - INTERVAL 30 MINUTE
    │            GROUP BY minute ORDER BY minute"}
    │   → Security: PromptGuard checks SQL for injection
    │   → Security: Custom SQL validator ensures SELECT-only, no mutations
    │   → Execute: Pillar query against ClickHouse
    │   → Result: [{minute: "14:30", p99: 245}, {minute: "14:31", p99: 890}, ...]
    │
    ├─ LLM sees the spike, decides to correlate with external services
    │   Tool: query_clickhouse
    │   Input: {sql: "SELECT service, endpoint, quantile(0.99)(response_time)...
    │            FROM log_services WHERE timestamp > '14:30'..."}
    │   → Result: [{service: "stripe", p99: 4200}, ...]
    │
    ├─ LLM sees Stripe is slow, checks job queue impact
    │   Tool: query_clickhouse
    │   Input: {sql: "SELECT count() as pending FROM job_monitoring
    │            WHERE event_type = 'start' AND job_name LIKE '%Payment%'
    │            AND timestamp > '14:30'
    │            AND id NOT IN (SELECT id FROM job_monitoring WHERE event_type = 'complete')"}
    │   → Result: [{pending: 47}]
    │
    ▼
Agent text response:
"The p99 spike started at 14:31, jumping from 245ms to 890ms. This correlates
 with Stripe API response times increasing to 4.2s (p99). As a result, 47
 payment-related background jobs are currently backed up in the queue. This is
 likely a Stripe-side issue — check status.stripe.com."
```

### Tools to Implement

```elixir
# lib/dashboard/tools/clickhouse_query.ex
defmodule Dashboard.Tools.ClickhouseQuery do
  @doc "Execute a read-only ClickHouse query. SQL is validated before execution."
  def execute(%{"sql" => sql}) do
    with :ok <- validate_read_only(sql),
         {:ok, result} <- Pillar.query(clickhouse(), sql, %{}, timeout: 10_000) do
      {:ok, Jason.encode!(result)}
    else
      {:error, reason} -> {:error, "Query failed: #{inspect(reason)}"}
    end
  end
end

# lib/dashboard/tools/anomaly_detector.ex
defmodule Dashboard.Tools.AnomalyDetector do
  @doc "Check current metrics against thresholds and return active anomalies."
  def execute(%{"window_minutes" => window}) do
    # Compare current window vs previous window
    # Return list of anomalies with severity, metric, current vs baseline values
  end
end
```

### System Prompt (Domain Context)

```
You are a monitoring assistant for a production Rails application.
You have access to three ClickHouse tables:

1. request_monitoring — HTTP requests (columns: timestamp, method, path,
   status, queue_time_ms, processing_time_ms, total_time_ms)
2. job_monitoring — Background jobs (columns: timestamp, job_name, queue_name,
   event_type [start|complete], queue_time_ms, run_time_ms)
3. log_services — External API calls (columns: timestamp, service, endpoint,
   response_time_ms, status)

Use the query_clickhouse tool to investigate. Always use time-bounded queries.
Never generate INSERT, UPDATE, DELETE, DROP, or ALTER statements.
When you find anomalies, explain the likely cause and suggest next steps.
```

### Ollama Support

ExClaw currently only supports Anthropic. izi_monitoring's design calls for dual-backend
(Anthropic for user queries, Ollama for high-frequency anomaly narration). Two options:

1. **Add Ollama backend to ExClaw** — new `ExClaw.LLM.OllamaProvider` GenServer alongside
   the existing Anthropic one. Agent Session takes a `:provider` option.
2. **Keep Ollama separate in izi_monitoring** — use ExClaw for the conversational agent
   (Anthropic), keep a lightweight Ollama client in the dashboard for automated anomaly
   summaries that don't need multi-turn tool use.

Option 2 is pragmatic for now. The anomaly narrator doesn't need an agent loop — it's a
single prompt with context in, summary out.

---

## tecdoc_importer Integration Detail

### What ExClaw Adds

The catalog currently requires users to navigate a multi-step UI flow:
Vehicle → GenArt → Brand → Article → Cross-references. An ExClaw agent turns this into
natural conversation.

### Agent Flow: Conversational Parts Lookup

```
User (via LiveView chat): "What brake pads fit a 2019 Golf GTI
                            and are also compatible with the Audi A3?"
    │
    ▼
ExClaw.Agent.Session (group_id: "catalog_user_456")
    │
    ├─ Tool: search_vehicles({query: "Golf GTI 2019"})
    │   → Calls Catalog.search_vehicles("Golf GTI 2019")
    │   → Result: [{ktype_id: 35448, name: "Golf VII GTI 2.0 TSI", year: "2017-2024"}]
    │
    ├─ Tool: search_vehicles({query: "Audi A3"})
    │   → Result: [{ktype_id: 42901, name: "A3 Sportback 2.0 TDI", year: "2016-2023"}, ...]
    │   (multiple results — agent picks most likely or asks user)
    │
    ├─ Tool: get_genarts({ktype_id: 35448, category: "brake pad"})
    │   → Calls Catalog.genarts_for_ktype(35448) filtered by description
    │   → Result: [{genart_id: 698, name: "Brake Pad Set, disc brake"}]
    │
    ├─ Tool: find_cross_references({genart_id: 698, ktype_ids: [35448, 42901]})
    │   → Calls Catalog.compatible_articles across both ktypes
    │   → Result: [{brand: "Bosch", article: "BP1234"}, {brand: "TRW", article: "GDB1887"}, ...]
    │
    ▼
"Three brands offer brake pads compatible with both the Golf GTI and the A3:
 - Bosch BP1234 (€45.90)
 - TRW GDB1887 (€38.50)
 - Brembo P85153 (€52.00)
 The Bosch part also fits the Skoda Octavia III (2017+)."
```

### Tools to Implement

```elixir
# lib/tecdoc_importer/tools/vehicle_search.ex
defmodule TecdocImporter.Tools.VehicleSearch do
  def execute(%{"query" => query}) do
    results = TecdocImporter.Catalog.search_vehicles(query)
    {:ok, format_vehicles(results)}
  end
end

# lib/tecdoc_importer/tools/article_search.ex
defmodule TecdocImporter.Tools.ArticleSearch do
  def execute(%{"brand" => brand, "article_number" => num}) do
    case TecdocImporter.Catalog.get_article(brand, num) do
      nil -> {:error, "Article not found"}
      article -> {:ok, format_article(article)}
    end
  end
end

# lib/tecdoc_importer/tools/cross_reference.ex
defmodule TecdocImporter.Tools.CrossReference do
  def execute(%{"article_id" => id}) do
    refs = TecdocImporter.Catalog.find_cross_references(id)
    {:ok, format_references(refs)}
  end
end

# lib/tecdoc_importer/tools/compatibility.ex
defmodule TecdocImporter.Tools.Compatibility do
  def execute(%{"article_id" => id}) do
    vehicles = TecdocImporter.Catalog.ktypes_for_article(id)
    {:ok, format_compatibility(vehicles)}
  end
end
```

### System Prompt (Domain Context)

```
You are an automotive parts catalog assistant. You help users find parts,
check compatibility across vehicles, and look up cross-references.

You have access to a TecDoc database with 50+ tables covering:
- Vehicles (manufacturers, models, types identified by KType number)
- Generic articles (GenArt — part categories like "brake pad", "oil filter")
- Articles (specific parts from specific brands/suppliers)
- Cross-references (OE numbers, trade numbers, substitute parts)
- Compatibility links (which articles fit which vehicles)

Available languages: Dutch (default), English, German, French.
When presenting results, include article numbers, brand names, and
vehicle compatibility. Offer to check cross-references when relevant.
```

### UI: Chat Component for Catalog

Add a floating chat widget or sidebar to the existing catalog UI:

```elixir
# lib/tecdoc_importer_web/live/chat_component.ex
defmodule TecdocImporterWeb.ChatComponent do
  use TecdocImporterWeb, :live_component

  # Renders a chat panel that sends messages to ExClaw.Agent.Session
  # Results can include clickable links to existing catalog pages
  # e.g., "Bosch BP1234" links to /articles/12345
end
```

---

## ExClaw Umbrella Structure (Decided)

The current single-project ExClaw is restructured into an umbrella with two apps:

- **`exclaw`** — the reusable library (no Application module, no `mod:` key)
- **`exclaw_app`** — the lean standalone runner (starts ExClaw + own channels, dashboard, scheduler, tools)

### Directory Layout

```
exclaw/                              # Umbrella root
├── apps/
│   ├── exclaw/                      # LIBRARY — reusable by izi_monitoring, tecdoc_importer
│   │   ├── lib/exclaw/
│   │   │   ├── llm/
│   │   │   │   ├── provider.ex          # Anthropic API client (GenServer)
│   │   │   │   ├── rate_limiter.ex      # Sliding-window token/request limiter
│   │   │   │   └── supervisor.ex
│   │   │   ├── agent/
│   │   │   │   ├── session.ex           # Multi-turn tool-use loop (GenServer per group)
│   │   │   │   └── supervisor.ex        # DynamicSupervisor, find-or-start
│   │   │   ├── security/
│   │   │   │   ├── file_guard.ex        # Path traversal, dotfile checks
│   │   │   │   ├── shell_sandbox.ex     # Dangerous command blocking
│   │   │   │   ├── prompt_guard.ex      # Prompt injection detection
│   │   │   │   └── supervisor.ex
│   │   │   ├── memory/
│   │   │   │   ├── store.ex             # Facts, MEMORY.md, message history
│   │   │   │   ├── fact.ex              # Ecto schema
│   │   │   │   ├── message.ex           # Ecto schema
│   │   │   │   └── supervisor.ex
│   │   │   ├── telemetry/               # Future: ClickHouse event logging
│   │   │   │   └── logger.ex
│   │   │   └── repo.ex                  # Ecto SQLite3 repo (optional, see below)
│   │   ├── test/
│   │   │   ├── security/                # 61 tests
│   │   │   ├── llm/                     # 28 tests
│   │   │   ├── agent/                   # 19 tests
│   │   │   └── memory/                  # 34 tests
│   │   └── mix.exs                      # NO mod: key — pure library
│   │
│   └── exclaw_app/                  # STANDALONE RUNNER — the lean app
│       ├── lib/exclaw_app/
│       │   ├── application.ex           # Starts ExClaw supervisors + own children
│       │   ├── channels/
│       │   │   └── cli.ex               # Terminal REPL (existing)
│       │   ├── dashboard/               # Phoenix LiveView (existing, in progress)
│       │   │   ├── supervisor.ex
│       │   │   └── live/
│       │   ├── scheduler/               # Quantum cron jobs (existing, in progress)
│       │   │   └── supervisor.ex
│       │   └── tools/                   # Shell, FileOps, WebSearch (tomorrow)
│       ├── lib/mix/tasks/
│       │   └── exclaw.cli.ex            # mix exclaw.cli entry point
│       ├── test/
│       │   ├── channels/                # 18 tests
│       │   ├── dashboard/
│       │   └── scheduler/
│       └── mix.exs                      # deps: [{:exclaw, in_umbrella: true}]
│
├── config/                          # Shared config for umbrella
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   └── prod.exs
└── mix.exs                          # Umbrella root mix.exs
```

### Umbrella Root mix.exs

```elixir
# mix.exs (umbrella root)
defmodule ExClaw.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    []  # All deps declared in individual app mix.exs files
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
```

### Library App mix.exs (apps/exclaw)

```elixir
# apps/exclaw/mix.exs
defmodule ExClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :exclaw,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  # NO application/0 callback with mod: — this is a library
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Core — minimal deps, no Phoenix, no Quantum
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug_crypto, "~> 2.0"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
```

### Standalone App mix.exs (apps/exclaw_app)

```elixir
# apps/exclaw_app/mix.exs
defmodule ExClawApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :exclaw_app,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExClawApp.Application, []}
    ]
  end

  defp deps do
    [
      {:exclaw, in_umbrella: true},

      # Web dashboard
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.0"},

      # Scheduler
      {:quantum, "~> 3.5"},

      # Tools
      {:floki, "~> 0.36"},

      # Dev/Test
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
```

### Standalone Application Module

```elixir
# apps/exclaw_app/lib/exclaw_app/application.ex
defmodule ExClawApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ExClaw library supervision tree
      ExClaw.Repo,
      {Phoenix.PubSub, name: ExClaw.PubSub},
      {Registry, keys: :unique, name: ExClaw.SessionRegistry},
      ExClaw.Security.Supervisor,
      ExClaw.LLM.Supervisor,
      ExClaw.Agent.Supervisor,
      ExClaw.Memory.Supervisor,

      # ExClawApp-specific children
      ExClawApp.Scheduler.Supervisor,
      ExClawApp.Dashboard.Supervisor
    ]

    opts = [strategy: :one_for_one, name: ExClawApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Host App Integration Pattern

When izi_monitoring or tecdoc_importer use ExClaw as a dependency, they start only
the library supervisors they need — no dashboard, no scheduler, no CLI:

```elixir
# In izi_monitoring or tecdoc_importer application.ex
children = [
  # ... existing children (PostgreSQL repo, Phoenix, etc.) ...

  # ExClaw library — cherry-pick what you need
  {Registry, keys: :unique, name: ExClaw.SessionRegistry},
  ExClaw.Security.Supervisor,
  ExClaw.LLM.Supervisor,
  ExClaw.Agent.Supervisor,
  # ExClaw.Memory.Supervisor only if you want ExClaw's memory (optional)
  # ExClaw.Repo only if using ExClaw's SQLite memory (optional)
]
```

Host app `config.exs`:

```elixir
config :exclaw, ExClaw.LLM.Provider,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  base_url: "https://api.anthropic.com/v1"

config :exclaw, ExClaw.LLM.RateLimiter,
  max_requests_per_minute: 30,
  max_tokens_per_minute: 100_000
```

### Dependency Declaration from External Projects

During development (path to umbrella app):

```elixir
# In izi_monitoring/mix.exs — point to the library app inside the umbrella
defp deps do
  [
    {:exclaw, path: "../../exClaw/exclaw/apps/exclaw"},
    # ... other deps ...
  ]
end
```

Later (git with sparse checkout or hex publish):

```elixir
{:exclaw, git: "https://github.com/alice/exclaw.git",
  sparse: "apps/exclaw", branch: "main"}
```

### What Moves Where

| Current location | Moves to | App |
|---|---|---|
| `lib/exclaw/security/*` | `apps/exclaw/lib/exclaw/security/*` | Library |
| `lib/exclaw/llm/*` | `apps/exclaw/lib/exclaw/llm/*` | Library |
| `lib/exclaw/agent/*` | `apps/exclaw/lib/exclaw/agent/*` | Library |
| `lib/exclaw/memory/*` | `apps/exclaw/lib/exclaw/memory/*` | Library |
| `lib/exclaw/repo.ex` | `apps/exclaw/lib/exclaw/repo.ex` | Library |
| `lib/exclaw/channels/cli.ex` | `apps/exclaw_app/lib/exclaw_app/channels/cli.ex` | Standalone |
| `lib/exclaw/dashboard/*` | `apps/exclaw_app/lib/exclaw_app/dashboard/*` | Standalone |
| `lib/exclaw/scheduler/*` | `apps/exclaw_app/lib/exclaw_app/scheduler/*` | Standalone |
| `lib/mix/tasks/exclaw.cli.ex` | `apps/exclaw_app/lib/mix/tasks/exclaw.cli.ex` | Standalone |
| `lib/exclaw/application.ex` | `apps/exclaw_app/lib/exclaw_app/application.ex` | Standalone |
| `config/*` | `config/*` (umbrella root) | Shared |
| `test/security/*` | `apps/exclaw/test/security/*` | Library |
| `test/llm/*` | `apps/exclaw/test/llm/*` | Library |
| `test/agent/*` | `apps/exclaw/test/agent/*` | Library |
| `test/memory/*` | `apps/exclaw/test/memory/*` | Library |
| `test/channels/*` | `apps/exclaw_app/test/channels/*` | Standalone |
| `test/dashboard/*` | `apps/exclaw_app/test/dashboard/*` | Standalone |
| `test/scheduler/*` | `apps/exclaw_app/test/scheduler/*` | Standalone |

### Module Renaming

Library modules keep the `ExClaw.*` namespace — they ARE the ExClaw library.

Standalone app modules move to `ExClawApp.*`:

| Old name | New name |
|---|---|
| `ExClaw.Application` | `ExClawApp.Application` |
| `ExClaw.Channels.CLI` | `ExClawApp.Channels.CLI` |
| `ExClaw.Dashboard.*` | `ExClawApp.Dashboard.*` |
| `ExClaw.Scheduler.*` | `ExClawApp.Scheduler.*` |
| `Mix.Tasks.Exclaw.Cli` | stays (Mix task name is convention-based) |

### Running

```bash
# From umbrella root — runs everything
mix exclaw.cli

# Tests — library only
mix test --app exclaw

# Tests — standalone only
mix test --app exclaw_app

# Tests — all
mix test
```

---

## ClickHouse Event Logging — Shared Infrastructure

### izi_monitoring

Already has ClickHouse (Pillar client). ExClaw's `Telemetry.Logger` writes to a new
`exclaw_events` table alongside the existing monitoring tables. Same ClickHouse instance,
new table. Gives unified observability: monitoring data AND AI agent behavior in one place.

```
ClickHouse instance (same server)
├── request_monitoring    ← existing Rails monitoring
├── job_monitoring        ← existing Rails monitoring
├── log_services          ← existing Rails monitoring
└── exclaw_events         ← NEW: AI agent telemetry (LLM calls, tool executions, etc.)
```

### tecdoc_importer

Needs a new ClickHouse connection. Options:
1. **Same ClickHouse instance** as izi_monitoring (if accessible) — simplest
2. **Separate ClickHouse instance** — if projects are on different servers
3. **Skip ClickHouse, use PostgreSQL** — if adding ClickHouse is too much infra for a catalog app

Recommendation: Start with option 3 (log to PostgreSQL or local JSONL files), add ClickHouse
when it's justified by volume.

---

## Implementation Order

### Phase 0: Finish Current Work
- [ ] Complete Dashboard (in progress)
- [ ] Complete Scheduler (in progress)
- [ ] Implement Tools: WebSearch, WebFetch, Shell, FileOps, Registry (tomorrow)

### Phase 1: Umbrella Restructuring
- [ ] Create umbrella root `mix.exs`
- [ ] Create `apps/exclaw/` — move library modules (security, llm, agent, memory, repo)
- [ ] Create `apps/exclaw_app/` — move app modules (channels, dashboard, scheduler, tools)
- [ ] Create `apps/exclaw/mix.exs` — no `mod:` key, minimal deps (ecto_sqlite3, jason, req, plug_crypto)
- [ ] Create `apps/exclaw_app/mix.exs` — `mod: {ExClawApp.Application, []}`, Phoenix/Quantum deps
- [ ] Rename app modules: `ExClaw.Channels.CLI` → `ExClawApp.Channels.CLI`, etc.
- [ ] Move tests to respective app test directories
- [ ] Move config to umbrella root
- [ ] Verify: `mix test --app exclaw` passes (142 tests — security, llm, agent, memory)
- [ ] Verify: `mix test --app exclaw_app` passes (18+ tests — channels, dashboard, scheduler)
- [ ] Verify: `mix test` passes all 162 tests
- [ ] Verify: `mix exclaw.cli` still works from umbrella root

### Phase 2: izi_monitoring Integration
- [ ] Add ExClaw as path dependency
- [ ] Start ExClaw supervisors in Dashboard.Application
- [ ] Implement ClickHouse query tool (wraps existing Pillar connection)
- [ ] Implement anomaly detection tool (uses existing threshold logic)
- [ ] Create system prompt with ClickHouse schema context
- [ ] Add LiveView ChatComponent wired to ExClaw.Agent.Session
- [ ] Add `exclaw_events` table to ClickHouse for agent telemetry
- [ ] Test: NL query → SQL → result → explanation flow end-to-end

### Phase 3: tecdoc_importer Integration
- [ ] Add ExClaw as path dependency
- [ ] Start ExClaw supervisors in TecdocImporter.Application
- [ ] Implement vehicle search tool (wraps Catalog.search_vehicles)
- [ ] Implement article search tool (wraps Catalog queries)
- [ ] Implement cross-reference tool (wraps Catalog.find_cross_references)
- [ ] Implement compatibility tool (wraps Catalog.ktypes_for_article)
- [ ] Create system prompt with TecDoc domain context
- [ ] Add LiveView ChatComponent to catalog UI
- [ ] Test: "find brake pads for Golf GTI" → multi-step tool use → formatted answer

### Phase 4: Shared Improvements
- [ ] ClickHouse event logging (ExClaw.Telemetry.Logger)
- [ ] Ollama backend for ExClaw.LLM (optional, for izi_monitoring cost optimization)
- [ ] Streaming responses (LiveView-friendly, token-by-token display)
- [ ] Tool behaviour with schema validation (Anthropic tool definitions auto-generated from Elixir typespecs)

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| ExClaw's Ecto repo conflicts with host app's repo | Build failure | Make ExClaw repo optional; use host app's repo or a separate one |
| ExClaw's SQLite conflicts with host's PostgreSQL | Runtime error | ExClaw memory can use host's PostgreSQL instead of its own SQLite |
| Security modules too restrictive for legitimate queries | False positives | PromptGuard tuning per domain; allow custom security rule overrides |
| Agent loop too slow for real-time dashboard | UX degradation | Async responses via LiveView (show loading, stream tokens when ready) |
| Rate limiter shared across both apps if same API key | Resource contention | Per-app rate limiter config, or separate API keys |

---

## Summary

ExClaw becomes the **AI brain** — LLM client, agent loop, security, memory. Each host project
provides the **domain tools** (ClickHouse queries, catalog lookups) and the **UI** (LiveView
components). Clean separation, no code duplication, independent evolution.

```
┌─────────────────────────────────────────────────┐
│                  ExClaw (library)                │
│  ┌───────────┐ ┌──────────┐ ┌────────────────┐  │
│  │ LLM.      │ │ Agent.   │ │ Security.*     │  │
│  │ Provider  │ │ Session  │ │ FileGuard      │  │
│  │ RateLimit │ │ Supervisor│ │ ShellSandbox   │  │
│  └───────────┘ └──────────┘ │ PromptGuard    │  │
│  ┌───────────┐ ┌──────────┐ └────────────────┘  │
│  │ Memory.   │ │Telemetry.│                      │
│  │ Store     │ │ Logger   │                      │
│  └───────────┘ └──────────┘                      │
└──────────────────┬──────────────────┬────────────┘
                   │                  │
        ┌──────────▼─────┐  ┌────────▼──────────┐
        │ izi_monitoring │  │ tecdoc_importer   │
        │                │  │                   │
        │ Tools:         │  │ Tools:            │
        │  query_ch      │  │  search_vehicles  │
        │  detect_anom   │  │  search_articles  │
        │  correlate     │  │  cross_reference  │
        │                │  │  compatibility    │
        │ UI:            │  │                   │
        │  ChatComponent │  │ UI:               │
        │  AnomalyAlert  │  │  ChatComponent    │
        │                │  │                   │
        │ Data:          │  │ Data:             │
        │  ClickHouse    │  │  PostgreSQL       │
        └────────────────┘  └───────────────────┘
```
