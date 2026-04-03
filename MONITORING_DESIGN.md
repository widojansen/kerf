# ExClaw Monitoring & Observability Design

**Phase:** A.5 (cross-cutting, alongside ApprovalGate and StructuredOutput)
**Status:** Design complete, ready for TDD build

## Purpose

Three questions this system answers:

1. **Is Tina alive and responsive?** — Not "is the OS process running" (systemd handles that), but is she processing Telegram messages, completing LLM calls, not stuck in a bad state.
2. **What happened?** — After the fact: which LLM calls were slow, what errors occurred, which agents restarted, what did the ApprovalGate decide.
3. **What's degrading?** — Proactive: is vLLM getting slower, is memory creeping, are message queues growing.

## Design Principles

- **Monitoring observes but never interferes** — a crash in Alerting must never take down ModelRouter or the Telegram adapter
- **Eat our own dogfood** — alerts go through Tina's own Telegram adapter
- **Bootstrapping fallback** — if Telegram itself is down, alerts fall back to Logger.error (→ journald)
- **90/10 applies here too** — deterministic health checks and thresholds, no LLM in the monitoring loop
- **Structured by default** — all log output is JSON in production for jq/journalctl queryability

---

## Supervision Tree Placement

```
ExClaw.Application (one_for_one)
├── ExClaw.Repo
├── ExClaw.Infrastructure.Supervisor
├── ExClaw.Agent.Supervisor
├── ExClaw.Telegram.Supervisor
├── ExClaw.Monitor.Supervisor (rest_for_one)  ← NEW
│   ├── ExClaw.Monitor.ProcessHealth          ← GenServer, periodic checks
│   ├── ExClaw.Monitor.TelemetryHandlers      ← attaches :telemetry handlers on init
│   └── ExClaw.Monitor.Alerting               ← GenServer, debounced alerts
└── ...
```

**Why `rest_for_one`:** If ProcessHealth crashes, Alerting must restart too (it depends on ProcessHealth's events). If Alerting crashes alone, ProcessHealth keeps running — health data isn't lost.

**Start order matters:** ProcessHealth starts first, begins emitting telemetry events. TelemetryHandlers attaches handlers that write to the telemetry_events table. Alerting starts last, subscribes to anomaly events and delivers notifications.

---

## Module Contracts

### 1. Structured JSON Logging (config change, no new module)

**File:** `config/prod.exs`

Replaces Elixir's default console backend with `LoggerJSON` in production. All Logger calls emit JSON to stdout → journald.

```elixir
# config/prod.exs
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: :all}
```

**Dependency:** `{:logger_json, "~> 6.0"}` in mix.exs

**Effect:** Every `Logger.info("LLM response", model: "qwen3-32b", latency_ms: 1200)` becomes:

```json
{"time":"2026-04-03T14:22:01.123Z","severity":"info","message":"LLM response","model":"qwen3-32b","latency_ms":1200}
```

Queryable via: `journalctl -u exclaw --output=cat | jq 'select(.model == "qwen3-32b" and .latency_ms > 10000)'`

---

### 2. ExClaw.Monitor.ProcessHealth

**Type:** GenServer
**Periodic interval:** 30 seconds (configurable via application env)
**Responsibility:** Inspect critical named processes, emit telemetry events for anomalies.

**Monitored processes (configurable list):**

```elixir
@default_watched_processes [
  ExClaw.Telegram.Poller,
  ExClaw.ModelRouter,
  ExClaw.Workflow.ApprovalGate.Manager,
  ExClaw.Scheduler,
  ExClaw.Agent.Supervisor,
  ExClaw.Infrastructure.Supervisor
]
```

**On each tick:**

For each process name in the watched list:
1. `Process.whereis(name)` — if nil, emit `[:exclaw, :monitor, :process_down]` telemetry event
2. `Process.info(pid, [:message_queue_len, :memory, :reductions])` — if queue > threshold, emit `[:exclaw, :monitor, :queue_high]`
3. Track restart counts by monitoring supervisor children via `Supervisor.count_children/1`

**Thresholds (application env, overridable):**

```elixir
config :exclaw, ExClaw.Monitor.ProcessHealth,
  interval_ms: 30_000,
  queue_high_threshold: 100,
  memory_high_threshold_mb: 256
```

**Telemetry events emitted:**

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:exclaw, :monitor, :process_down]` | `%{}` | `%{name: atom}` |
| `[:exclaw, :monitor, :queue_high]` | `%{queue_len: integer}` | `%{name: atom, threshold: integer}` |
| `[:exclaw, :monitor, :memory_high]` | `%{memory_mb: float}` | `%{name: atom, threshold: integer}` |
| `[:exclaw, :monitor, :health_check]` | `%{duration_us: integer}` | `%{process_count: integer, all_healthy: boolean}` |

**State:**

```elixir
%{
  watched: [atom()],
  interval_ms: integer(),
  thresholds: %{queue_high: integer(), memory_high_mb: integer()},
  timer_ref: reference()
}
```

**Public API:**

```elixir
@callback status() :: %{atom() => :ok | :down | {:degraded, reason :: String.t()}}
@callback add_watch(process_name :: atom()) :: :ok
@callback remove_watch(process_name :: atom()) :: :ok
```

---

### 3. ExClaw.Monitor.TelemetryHandlers

**Type:** Module with `init/0` called from `start_link` (thin GenServer that attaches handlers on init, then idles)
**Responsibility:** Attach `:telemetry` handlers for BEAM VM metrics, LLM calls, Ecto queries, and process health events. Write events to PostgreSQL `telemetry_events` table.

**Handlers attached:**

```elixir
# BEAM VM metrics (via telemetry_poller)
:telemetry_poller measures:
  - {:process_info, name: :exclaw_total_processes, event: [:vm, :process_count], measurement: :total}
  - memory: [:vm, :memory]
  - total_run_queue_lengths: [:vm, :total_run_queue_lengths]

# LLM provider events (emitted by VLLMProvider, AnthropicProvider, OllamaProvider)
[:exclaw, :llm, :call, :stop]     → log model, latency, tokens_in, tokens_out, status
[:exclaw, :llm, :call, :exception] → log model, error, duration

# Ecto query events
[:exclaw, :repo, :query]           → log source, query_time_ms (only if > 100ms)

# Process health events (from ProcessHealth)
[:exclaw, :monitor, :process_down] → log + trigger alert
[:exclaw, :monitor, :queue_high]   → log + trigger alert
[:exclaw, :monitor, :memory_high]  → log + trigger alert
```

**Dependency:** `{:telemetry_poller, "~> 1.1"}` in mix.exs (telemetry_poller ships with Phoenix but explicit is safer)

**Storage — PostgreSQL `telemetry_events` table:**

```elixir
# Migration
create table(:telemetry_events) do
  add :event_name, :string, null: false          # "llm.call.stop", "monitor.process_down"
  add :measurements, :map, null: false, default: %{}  # JSONB
  add :metadata, :map, null: false, default: %{}      # JSONB
  timestamps(updated_at: false)                   # inserted_at only
end

create index(:telemetry_events, [:event_name])
create index(:telemetry_events, [:inserted_at])
```

**No auto-pruning yet.** Retention policy deferred — table will grow; manual cleanup or future cron job.

**Write path:** Telemetry handlers call `ExClaw.Repo.insert/1` directly. If the insert fails (e.g., Repo is down), the handler logs to Logger.warning and moves on — telemetry must never crash the caller.

---

### 4. ExClaw.Monitor.Alerting

**Type:** GenServer
**Responsibility:** Receive anomaly events, debounce, deliver alerts via Telegram. Fall back to Logger.error if Telegram is unavailable.

**Debounce window:** 5 minutes per alert key. If the same alert fires again within 5 minutes, it is suppressed. After 5 minutes, a new occurrence triggers a fresh alert.

**Alert key:** `{event_name, metadata_subset}` — e.g., `{:process_down, %{name: ExClaw.ModelRouter}}` is one key, `{:process_down, %{name: ExClaw.Scheduler}}` is another.

**State:**

```elixir
%{
  debounce_window_ms: integer(),           # 300_000 (5 min)
  last_fired: %{alert_key => DateTime.t()}, # tracks when each alert last fired
  telegram_chat_id: String.t(),            # your personal chat ID for alerts
  active_incidents: %{alert_key => DateTime.t()}  # for recovery detection
}
```

**Alert lifecycle:**

1. Anomaly telemetry event fires (from ProcessHealth or TelemetryHandlers)
2. Alerting receives it via `:telemetry.attach`
3. Check debounce: if `last_fired[key]` is within 5 minutes, suppress
4. If not suppressed: send Telegram message, record in `last_fired`, add to `active_incidents`
5. On next ProcessHealth tick, if the condition is resolved: send recovery message, remove from `active_incidents`

**Recovery messages:** "✅ ExClaw.ModelRouter recovered (was down for 3m 22s)" — these are not debounced.

**Telegram delivery:**

```elixir
defp send_alert(message, state) do
  case ExClaw.Telegram.send_message(state.telegram_chat_id, message) do
    {:ok, _} -> :ok
    {:error, reason} ->
      Logger.error("Alert delivery failed: #{inspect(reason)}", alert: message)
  end
end
```

**Bootstrapping problem:** If `ExClaw.Telegram.Poller` itself is down, we can't send via Telegram. The `Logger.error` fallback ensures the alert reaches journald. A future enhancement could add a direct HTTP call to the Telegram API (bypassing the adapter) as a secondary fallback, but Logger is sufficient for now.

**Alert message format:**

```
🔴 ExClaw Alert: ModelRouter DOWN
Process ExClaw.ModelRouter is not running.
Detected at 2026-04-03 14:22:01 UTC
```

```
⚠️ ExClaw Alert: Telegram.Poller queue high
Message queue: 342 (threshold: 100)
Detected at 2026-04-03 14:22:01 UTC
```

**Configuration:**

```elixir
config :exclaw, ExClaw.Monitor.Alerting,
  debounce_window_ms: 300_000,
  telegram_chat_id: System.get_env("TELEGRAM_ALERT_CHAT_ID")
```

---

### 5. LLM Provider Telemetry (instrumentation in existing modules)

**No new module.** Add `:telemetry.span/3` calls to `VLLMProvider.chat/2`, `AnthropicProvider.chat/2`, and `OllamaProvider.chat/2`.

**Pattern:**

```elixir
def chat(messages, opts) do
  metadata = %{model: opts[:model], provider: :vllm}

  :telemetry.span([:exclaw, :llm, :call], metadata, fn ->
    case do_chat(messages, opts) do
      {:ok, response} = result ->
        measurements = %{
          tokens_in: response.usage.prompt_tokens,
          tokens_out: response.usage.completion_tokens,
          status: :ok
        }
        {result, measurements}

      {:error, _} = result ->
        {result, %{status: :error}}
    end
  end)
end
```

This emits `[:exclaw, :llm, :call, :start]`, `[:exclaw, :llm, :call, :stop]`, and `[:exclaw, :llm, :call, :exception]` events automatically. TelemetryHandlers (step 3) picks them up.

---

### 6. BEAM VM Metrics via telemetry_poller

**No new module.** Configuration only.

```elixir
# config/config.exs (or application.ex children)
{:telemetry_poller,
  measurements: [
    {:process_info, event: [:vm, :process_count], name: :total},
    :memory,
    :total_run_queue_lengths
  ],
  period: 30_000  # every 30 seconds, aligned with ProcessHealth
}
```

TelemetryHandlers attaches to these events and writes them to `telemetry_events`. This gives you historical BEAM metrics: process count, memory breakdown (total, processes, binary, ets, atom), and scheduler run queue depths.

---

## What This Does NOT Cover (Future Work)

- **ClickHouse integration** — deferred; PostgreSQL telemetry_events is sufficient for now
- **Phoenix LiveDashboard enhancements** — the existing dashboard on :4000 already shows sessions, rate limiter, memory; these new metrics could feed custom LiveDashboard pages later
- **Multi-tenant alerting** — commercial version would need per-tenant alert channels and thresholds
- **Telegram digest** — a daily/weekly summary message ("Tina processed 342 LLM calls this week, avg latency 2.1s, 3 process restarts") is a natural follow-up
- **External uptime monitoring** — something outside the Spark that checks if ExClaw is reachable (guards against the whole machine going down)
- **Auto-pruning of telemetry_events** — retention policy TBD

---

## TDD Build Sequence

Follow Red-Prompt-Green-Refactor for each step.

### Step 1: Structured JSON Logging

1. Add `{:logger_json, "~> 6.0"}` to mix.exs
2. Configure `config/prod.exs` with LoggerJSON formatter
3. Test: start app in prod mode, verify JSON output format
4. Verify: `Logger.info("test", custom_key: "value")` includes `custom_key` in JSON

### Step 2: telemetry_events Migration + Schema

1. **Red:** Write test that `ExClaw.Monitor.TelemetryEvent` changeset validates required fields
2. **Green:** Create migration, create Ecto schema with changeset
3. **Refactor:** Add indexes, verify JSONB columns work with map data

### Step 3: ExClaw.Monitor.ProcessHealth GenServer

1. **Red:** Test that `ProcessHealth.status/0` returns `:ok` for all watched processes when they're running
2. **Green:** Implement GenServer with periodic timer, `Process.whereis` + `Process.info` checks
3. **Red:** Test that a missing process emits `[:exclaw, :monitor, :process_down]` telemetry event
4. **Green:** Add telemetry emission for anomalies
5. **Red:** Test that high message queue emits `[:exclaw, :monitor, :queue_high]`
6. **Green:** Add queue threshold check
7. **Refactor:** Extract threshold config to application env, add `add_watch/1` and `remove_watch/1`

### Step 4: ExClaw.Monitor.TelemetryHandlers

1. **Red:** Test that attaching handlers and emitting a telemetry event writes a row to `telemetry_events`
2. **Green:** Implement handler attachment in `init/0`, write handler functions that insert into Repo
3. **Red:** Test that handler failure (Repo down) doesn't crash the caller
4. **Green:** Wrap inserts in try/rescue, log warning on failure
5. **Red:** Test telemetry_poller VM metrics are captured
6. **Green:** Add telemetry_poller to supervision tree, attach VM metric handlers

### Step 5: ExClaw.Monitor.Alerting GenServer

1. **Red:** Test that a `:process_down` event triggers a Telegram message (mock Telegram adapter)
2. **Green:** Implement GenServer that subscribes to anomaly events and calls Telegram
3. **Red:** Test debounce: same alert within 5 minutes is suppressed
4. **Green:** Add `last_fired` map with timestamp comparison
5. **Red:** Test recovery: when process comes back, send recovery message
6. **Green:** Add `active_incidents` tracking with recovery detection
7. **Red:** Test fallback: when Telegram send fails, Logger.error is called
8. **Green:** Add fallback in `send_alert/2`
9. **Refactor:** Extract alert formatting, add configuration for debounce window and chat ID

### Step 6: LLM Provider Instrumentation

1. **Red:** Test that `VLLMProvider.chat/2` emits `[:exclaw, :llm, :call, :stop]` with model and latency
2. **Green:** Wrap existing `do_chat` in `:telemetry.span/3`
3. **Repeat** for AnthropicProvider and OllamaProvider
4. **Integration test:** Full round trip — LLM call → telemetry event → TelemetryHandlers → row in telemetry_events

### Step 7: Monitor.Supervisor + Integration

1. Wire `ExClaw.Monitor.Supervisor` into `ExClaw.Application` children
2. Verify `rest_for_one` strategy: kill Alerting, confirm ProcessHealth survives
3. Verify start order: ProcessHealth → TelemetryHandlers → Alerting
4. End-to-end: stop a watched process, verify alert arrives on Telegram within 30s

---

## Dependencies to Add

```elixir
# mix.exs
defp deps do
  [
    {:logger_json, "~> 6.0"},
    {:telemetry_poller, "~> 1.1"},
    # :telemetry is already a transitive dep via Phoenix/Ecto
  ]
end
```

---

## Configuration Summary

```elixir
# config/prod.exs
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: :all}

# config/config.exs
config :exclaw, ExClaw.Monitor.ProcessHealth,
  interval_ms: 30_000,
  queue_high_threshold: 100,
  memory_high_threshold_mb: 256

config :exclaw, ExClaw.Monitor.Alerting,
  debounce_window_ms: 300_000,
  telegram_chat_id: {:system, "TELEGRAM_ALERT_CHAT_ID"}
```
