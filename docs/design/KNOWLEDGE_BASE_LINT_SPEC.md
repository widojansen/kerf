# Knowledge Base Lint Spec

## Context

ExClaw's Knowledge Base accumulates state across multiple ingestion sources (Gmail today; more channels planned). Every email becomes a `Document` + `Chunks` + an `EmailSender` row + potentially an `Interest` match + a `Feedback` record + AGE graph edges. After weeks of ingestion this state drifts: orphan documents with no chunks, chunks with null embeddings, senders whose `is_priority` no longer matches their feedback history, interests that never match anything, AGE nodes that point at deleted documents, FastClassifier rules that contradict learned sender scores.

The Karpathy/Kosuri "wiki lint" pattern (raw → derived → schema, with a periodic lint pass to catch contradictions and orphans) maps directly onto this. The KB is ExClaw's wiki; ingestors write to it; downstream agents read from it. Without a lint pass, drift is invisible until it shows up as a triage failure (see `EMAIL_TRIAGE_DIAGNOSTIC_SPEC.md` — many of the diagnostics there are *exactly* the checks a lint module would automate).

This spec defines `ExClaw.KnowledgeBase.Lint` — a deterministic, read-mostly hygiene pass over the KB, runnable via Mix task or scheduled, that produces a structured report and optionally applies safe auto-repairs.

**Out of scope:** LLM-judged "is this content good" lint (deferred — requires separate-model verification per #4 self-evaluation bias finding). This spec is purely structural/relational consistency.

---

## Goals

1. Detect drift in the KB before it manifests as agent failures
2. Auto-repair the safe subset (re-embed null-vector chunks, mark orphans, refresh denormalized counts)
3. Surface the unsafe subset as a structured report for human decision
4. Run cheap enough to schedule weekly (target: <30s on current KB size)

## Non-goals

- Replacing the diagnostic queries in `EMAIL_TRIAGE_DIAGNOSTIC_SPEC.md` (those are one-shot incident tools; lint is periodic hygiene)
- LLM-based content quality checks
- Cross-tenant lint (single-tenant assumption holds for now)
- Modifying source data (`Document.content`, `EmailSender.email`) — lint only touches derived/denormalized fields

---

## Module Layout

```
lib/exclaw/knowledge_base/lint.ex                    # facade
lib/exclaw/knowledge_base/lint/check.ex              # behaviour
lib/exclaw/knowledge_base/lint/checks/               # individual checks
  embeddings.ex
  orphans.ex
  senders.ex
  interests.ex
  graph.ex
  fast_classifier.ex
lib/exclaw/knowledge_base/lint/report.ex             # structured findings
lib/exclaw/knowledge_base/lint/repair.ex             # safe auto-fixes
lib/mix/tasks/exclaw.kb.lint.ex                      # CLI entry point
test/exclaw/knowledge_base/lint_test.exs
test/exclaw/knowledge_base/lint/checks/*_test.exs
```

Follows the existing `ExClaw.KnowledgeBase.*` namespacing (`Document`, `Chunk`, `Interest`, `Feedback`, `EmailSender`, `Chunker`, `Embedder`, `Graph`).

---

## Behaviour

```elixir
defmodule ExClaw.KnowledgeBase.Lint.Check do
  @moduledoc """
  A single lint check. Pure read in `run/1`; any mutation belongs in `repair/2`
  on the parent module and must be opt-in.
  """

  @type severity :: :info | :warning | :error
  @type finding :: %{
          check: atom(),
          severity: severity(),
          subject: %{kind: atom(), id: term()} | :global,
          message: String.t(),
          repairable: boolean(),
          repair_hint: String.t() | nil,
          metadata: map()
        }

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback run(opts :: keyword()) :: {:ok, [finding()]} | {:error, term()}
end
```

`severity` maps to action:
- `:info` — observed but not actionable (e.g. "27 senders below priority threshold")
- `:warning` — drift that won't break things today but will compound (e.g. "12 chunks with null embeddings")
- `:error` — something the pipeline depends on is broken (e.g. "Interest seeded but has no embedding — InterestMatcher will silently return [] for every email")

---

## Facade

```elixir
defmodule ExClaw.KnowledgeBase.Lint do
  @moduledoc """
  Periodic structural consistency check over the Knowledge Base.

  ## Usage

      iex> ExClaw.KnowledgeBase.Lint.run()
      {:ok, %ExClaw.KnowledgeBase.Lint.Report{...}}

      iex> ExClaw.KnowledgeBase.Lint.run(checks: [:embeddings, :orphans])
      {:ok, %ExClaw.KnowledgeBase.Lint.Report{...}}

      iex> ExClaw.KnowledgeBase.Lint.run_and_repair(safe_only: true)
      {:ok, %ExClaw.KnowledgeBase.Lint.Report{...}, repairs_applied: 3}
  """

  @default_checks [
    ExClaw.KnowledgeBase.Lint.Checks.Embeddings,
    ExClaw.KnowledgeBase.Lint.Checks.Orphans,
    ExClaw.KnowledgeBase.Lint.Checks.Senders,
    ExClaw.KnowledgeBase.Lint.Checks.Interests,
    ExClaw.KnowledgeBase.Lint.Checks.Graph,
    ExClaw.KnowledgeBase.Lint.Checks.FastClassifier
  ]

  @spec run(keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(opts \\ [])

  @spec run_and_repair(keyword()) :: {:ok, Report.t(), non_neg_integer()} | {:error, term()}
  def run_and_repair(opts \\ [])
end
```

Options:
- `:checks` — atom list (`:embeddings`, `:orphans`, etc.) or modules; default = all
- `:since` — only inspect rows updated after this `DateTime`; default = nil (full scan)
- `:safe_only` — only apply repairs marked `repairable: true` AND with `severity != :error`; default true
- `:dry_run` — log what repair *would* do; default false
- `:emit_telemetry` — emit `[:exclaw, :kb, :lint, :*]` events; default true

---

## Checks

Each check is independently testable and individually runnable. Concrete spec for each:

### 1. `Checks.Embeddings`

**Goal:** catch missing/dimensionally-wrong embeddings before they cause silent failures in `InterestMatcher` or vector search.

**Findings produced:**
- `interest_missing_embedding` — `Interest` row with `embedding IS NULL` → `:error` (this is the #1 cause of the email triage failure pattern documented in `EMAIL_TRIAGE_DIAGNOSTIC_SPEC.md`); repairable via `Embedder.embed/1` on `name <> " " <> description`
- `chunk_missing_embedding` — `Chunk` row with `embedding IS NULL` → `:warning`; repairable
- `embedding_dim_mismatch` — vector length != 1024 → `:error`; not repairable (drop + re-embed needed, requires human)
- `embedding_zero_vector` — all-zero or near-zero vector (norm < 1e-6) → `:warning`; repairable

**Implementation note:** Use a single SQL pass per table; `pgvector` exposes vector dimension and norm functions. Don't load embeddings into the BEAM unless needed.

```elixir
# pseudo
from(i in Interest, where: is_nil(i.embedding), select: i.id)
|> Repo.all()
```

**Tests:**
- Seed an Interest without embedding → check produces `:error` finding, repair backfills it
- Seed a Chunk with null embedding → repair backfills via Embedder mock
- Seed a Chunk with 512-dim vector (wrong) → check produces `:error` finding, repair NOT applied

### 2. `Checks.Orphans`

**Goal:** catch dangling rows whose parent was deleted or whose pipeline stage failed.

**Findings produced:**
- `document_no_chunks` — `Document` with `status: :indexed` but zero chunks → `:warning`; repairable via re-chunking through `Chunker`
- `chunk_no_document` — `Chunk` whose `document_id` doesn't resolve → `:error`; repairable (delete the chunk)
- `feedback_no_document` — `Feedback` whose `document_id` doesn't resolve → `:warning`; repairable (delete)
- `sender_no_emails` — `EmailSender` with `total_emails: 0` and no associated documents → `:info`; repairable (delete) but only if older than 30 days (avoid racing with ingestor)

### 3. `Checks.Senders`

**Goal:** keep `EmailSender` denormalized counters and priority flags consistent with actual feedback history.

**Findings produced:**
- `sender_count_drift` — `total_emails` or `total_interactions` disagrees with actual document count by >5 → `:warning`; repairable (recount + UPDATE)
- `sender_priority_inverted` — `is_priority: true` but recent feedback (last 30 days) is mostly `:archive` → `:warning`; not auto-repairable (human decision; emit suggestion only)
- `sender_priority_stale` — `is_priority: true` but `last_email_at` > 180 days ago → `:info`; not auto-repairable
- `sender_override_orphan` — `priority_override` set but no `match_pattern` or `email` → `:error`; not auto-repairable

**Implementation note:** "recount + UPDATE" should be one SQL UPDATE FROM, not a per-row Ecto round trip. KB grows fast.

### 4. `Checks.Interests`

**Goal:** catch interests that are seeded but never used (dead weight) or that compete with each other.

**Findings produced:**
- `interest_zero_matches` — `Interest` exists but no `Feedback` row references a document that ever matched it (proxy: cosine search over last 100 documents returns zero hits above threshold for this interest) → `:info`; not repairable (human decides whether to drop or rewrite)
- `interest_dominates` — single `Interest` matches >70% of documents in last 100 → `:warning`; suggests poorly-tuned or too-broad description
- `interest_weight_zero` — `weight: 0` interest still active → `:info`; suggests delete

**Cost note:** This check runs cosine search; cap at last 100 documents and limit to 12-ish interests. Should still finish in <5s.

### 5. `Checks.Graph`

**Goal:** AGE graph nodes/edges should be in sync with the relational tables they mirror.

**Findings produced:**
- `graph_node_orphan` — Cypher node exists but its referenced `document_id` / `sender_id` is gone → `:warning`; repairable (delete node + cascade edges)
- `graph_edge_dangling` — edge endpoints don't resolve → `:warning`; repairable
- `graph_thread_loop` — thread reply edges form a cycle → `:error`; not repairable (Gmail bug; flag for inspection)

**Implementation note:** Use `KnowledgeBase.Graph.query/1` (existing Cypher helper) to count, not to extract. AGE's `count(*)` wrapper is already in the helper module per `MODULE_MAP.md`.

### 6. `Checks.FastClassifier`

**Goal:** `FastClassifier` rules (141 of them per current MODULE_MAP) shouldn't contradict learned sender scores.

**Findings produced:**
- `fast_rule_contradicts_sender` — rule says "high priority" but matching `EmailSender` has `priority_score < threshold` (or vice versa) → `:warning`; not repairable (human decision)
- `fast_rule_orphan` — rule references an email/pattern/domain with zero matches in last 90 days → `:info`; not repairable but flagged for cleanup
- `fast_rule_duplicate` — two rules with same email/pattern → `:error`; not repairable

**Cache invalidation:** if Senders or FastClassifier checks make any UPDATE, lint MUST call `FastClassifier.Cache.refresh/0` at the end.

---

## Report

```elixir
defmodule ExClaw.KnowledgeBase.Lint.Report do
  defstruct [
    :started_at,
    :finished_at,
    :duration_ms,
    :checks_run,         # [atom]
    :findings,           # [Check.finding()]
    :counts,             # %{info: n, warning: n, error: n}
    :repairs_applied,    # [%{check, subject, action}]
    :repairs_skipped     # [%{check, subject, reason}]
  ]

  @spec to_telegram(t()) :: String.t()
  @spec to_text(t()) :: String.t()
  @spec to_map(t()) :: map()  # for ClickHouse / dashboard ingestion
end
```

Rendering:
- `to_text/1` for Mix task output (grouped by severity, then by check)
- `to_telegram/1` for the scheduled-run notification (use existing `ApprovalGate.TelegramRenderer` style — header summary + collapsed per-check sections, errors only by default)
- `to_map/1` for telemetry / dashboard consumption

---

## Repair semantics

Two layers:

1. **`Lint.run/1`** — pure read. Never writes. Always safe.
2. **`Lint.run_and_repair/1`** — applies the repair function for each finding where `repairable: true` AND (`safe_only: false` OR `severity in [:info, :warning]`). Errors are NEVER auto-repaired (they imply something the developer should look at).

Each repair is idempotent and wrapped in its own transaction. A repair failure doesn't abort other repairs — collected into `repairs_skipped` with the reason.

Repairs that touch the AGE graph and the relational tables together must use a single `Repo.transaction/1` to avoid half-committed state.

---

## Mix Task

```elixir
defmodule Mix.Tasks.Exclaw.Kb.Lint do
  @moduledoc """
  Run the Knowledge Base lint pass.

  ## Examples

      mix exclaw.kb.lint                              # all checks, no repair
      mix exclaw.kb.lint --check embeddings           # one check
      mix exclaw.kb.lint --repair                     # safe auto-repair
      mix exclaw.kb.lint --repair --include-warnings  # repair :info + :warning
      mix exclaw.kb.lint --since "2026-04-01"         # incremental
      mix exclaw.kb.lint --format json > lint.json
  """
  use Mix.Task
  @shortdoc "Lint the Knowledge Base for structural drift"
end
```

Exit code: 0 if no `:error` findings; 1 if any `:error` findings remain after repair (so it can be wired to CI / pre-deploy hook).

---

## Scheduled Run

Wire into `ExClaw.Scheduler` (existing GenServer per MODULE_MAP):

```elixir
# in application.ex children, or via Scheduler.schedule/3 at boot
ExClaw.Scheduler.schedule(
  :kb_lint_weekly,
  "0 4 * * 1",  # Monday 04:00
  fn ->
    {:ok, report} = ExClaw.KnowledgeBase.Lint.run_and_repair(safe_only: true)
    if report.counts.error > 0 do
      ExClaw.Channels.Telegram.send_admin(
        ExClaw.KnowledgeBase.Lint.Report.to_telegram(report)
      )
    end
  end
)
```

Configurable via `config :exclaw, ExClaw.KnowledgeBase.Lint, schedule: "0 4 * * 1", enabled: true`.

---

## Telemetry

Emit:
- `[:exclaw, :kb, :lint, :start]` — `%{checks: n}`, `%{}`
- `[:exclaw, :kb, :lint, :check]` — `%{duration_ms: n, findings: n}`, `%{check: atom}`
- `[:exclaw, :kb, :lint, :repair]` — `%{count: n}`, `%{check: atom, severity: atom}`
- `[:exclaw, :kb, :lint, :stop]` — `%{duration_ms: n, info: n, warning: n, error: n}`, `%{}`

Existing `Monitor.TelemetryHandlers` will persist these to `telemetry_events`. No schema change required.

---

## Dashboard

Add a `lib/exclaw/dashboard/live/kb_lint_page.ex` LiveDashboard `additional_pages` entry. Two sections:

1. Last run summary (timestamp, counts, duration)
2. Findings table (filterable by severity + check, paginated)

Wire in `ExClaw.Dashboard.RouterPlug` (or wherever `additional_pages` is configured per `REMOVE_STANDALONE_DASHBOARD_SPEC.md`).

Defer initially — ship Mix task + scheduled run first, dashboard in a follow-up.

---

## Test Plan

Tests live under `test/exclaw/knowledge_base/lint/`. Each check has its own test module with seeded fixtures.

### Per-check tests (TDD: write these first)

For each check:
1. **No findings on clean DB** — empty result, no false positives
2. **Specific drift produces specific finding** — seed exact bad state, assert finding shape
3. **Repair fixes it** — apply repair, re-run check, assert no findings
4. **Repair is idempotent** — apply repair twice, no errors, second is no-op
5. **Severity boundaries** — `:error` cases are NOT auto-repaired in `safe_only: true`

### Facade tests

1. `run/1` with `:checks` filter only runs requested checks
2. `run/1` with `:since` only inspects rows updated after datetime
3. `run_and_repair/1` rolls back if a repair raises
4. `run_and_repair/1` continues other repairs if one fails (collected in `repairs_skipped`)
5. Telemetry events emitted with expected names + measurements
6. Cache invalidation — after Senders or FastClassifier repair, `FastClassifier.Cache.refresh/0` was called (use Mox)

### Integration test

Seed a KB with deliberate cross-cutting drift (orphan chunk + missing interest embedding + sender count drift simultaneously) and assert one full lint pass detects all of them and repairs the repairable subset in <5s.

### Mix task tests

Use `Mix.Task.run/2` capture; assert exit codes and stdout structure for each format.

---

## Workflow (SDD/TDD)

1. Write `Lint.Check` behaviour + test fixture helpers
2. Write `Checks.Embeddings` test FIRST (failing) — this is the highest-value check (it's the actual bug pattern from `EMAIL_TRIAGE_DIAGNOSTIC_SPEC.md`); make it pass
3. Repeat per check, in priority order: Embeddings → Orphans → Senders → Interests → Graph → FastClassifier
4. Wire facade after first 2 checks exist (don't pre-build the facade with no checks behind it)
5. Wire Mix task after facade
6. Wire scheduler entry after one full manual run on prod KB succeeds
7. Defer dashboard until lint has been running scheduled for ≥2 weeks

`mix compile --warnings-as-errors` and `mix dialyzer` via existing PostToolUse hooks. `mix credo --strict` should pass before merge.

---

## Open Questions

1. Should the lint report be persisted? Telemetry covers events but not the report-as-document. Probably yes — add a `kb_lint_runs` table with JSONB for the full report. Defer until needed.
2. Should `interest_zero_matches` use the live Embedder or a sampled cache? Live is more accurate but adds embedder latency to lint runs. Start with live; revisit if scheduled lint exceeds 30s.
3. Cross-check with `Memory.Store`? The agent memory is a separate state space; arguably deserves its own `ExClaw.Memory.Lint`. Out of scope here, flagged for later.
4. Should AGE graph orphan repair also drop the corresponding telemetry trail? Probably no — telemetry should be append-only.

---

## Success Criteria

- [ ] `mix exclaw.kb.lint` runs end-to-end on prod KB in <30s
- [ ] First scheduled run detects ≥1 finding (verifies it's not a no-op shell)
- [ ] Auto-repair fixes all `interest_missing_embedding` findings (closing the loop on `EMAIL_TRIAGE_DIAGNOSTIC_SPEC.md`'s root cause)
- [ ] No false-positive `:error` findings after 4 consecutive scheduled runs
- [ ] Test suite stays under +5% wall-clock vs. pre-lint baseline (currently 870 tests, target: ≤5% growth in time, even with new tests)
