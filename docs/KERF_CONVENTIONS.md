# Kerf — Project Conventions

**Status:** Living document. Grow as new conventions emerge from build sessions.
**Date created:** 2026-05-12
**Purpose:** Capture "how Kerf does things" — emergent conventions discovered during construction. These aren't specs (no "what to build"), aren't deferred work (no "for later"). They're the principles to reach for when designing the *next* thing.

Each entry: name, principle, why, where it's applied. Keep entries short; depth lives in the code and the deferred-work spec.

---

## Schema and data model

### Audit-log timestamps vs state-machine timestamps

**Principle:** Insert-only audit-log tables get `timestamps(updated_at: false)`. State-machine tables (anything with a mutable status column) get both `inserted_at` and `updated_at`.

**Why:** An audit log records "this happened at time T" — there's nothing to update. A state machine records "this thing's current state is X" — the latest transition's timestamp matters and naturally lands in `updated_at`. Mixing the conventions makes table semantics unclear at a glance.

**Where applied:**
- Audit-log: `kb_feedback` (Phase B), `email_routing_decisions` (Step 9)
- State-machine: `email_triage` (`triage_status` transitions through pending → classified → enriched), `email_senders` (priority/classification mutations)

### Include the source-of-truth version in audit rows

**Principle:** When an audit row records a decision made by code that reads from configuration or rules, include the config/rule version that produced the decision as a column on the row.

**Why:** Without it, correlating "behavior change on date X" to "config change on date Y" requires joining against deploy timestamps or git history — painful manually, impossible from a SQL dashboard. With it, `SELECT version, count(*) FROM <table> GROUP BY version` answers the question in one query.

**Where applied:**
- `email_routing_decisions.routing_config_version` (records the active `RoutingConfig` version at the moment of decision)
- *Future:* any decision-recording audit table where the decision logic could change over time (FastClassifier rule version, taxonomy version, etc.)

### Dual-purpose tables carry a discriminator

**Principle:** When a table holds rows representing fundamentally different kinds of entities (e.g. real records vs synthetic rule rows), there must be a discriminator column or convention that lets queries distinguish them — and every query that treats the table as one kind must filter for that kind.

**Why:** Forgetting the filter produces silently wrong results — e.g. "top correspondents by `total_emails`" returning synthetic rule rows with `total_emails: 0`.

**Where applied:**
- `email_senders`: real senders vs synthetic rule rows from `mix kerf.sync_sender_rules`. Discriminator: `domain = 'fast-classifier'` (rules) vs anything else (real). Filter pattern: `WHERE domain != 'fast-classifier'` for queries about real correspondents.

---

## Code organization

### Always-on defensive measures belong at the source

**Principle:** Defensive code (sanitization, validation, error-wrapping) should live as close to the source of the risk as possible — not in each consumer. If multiple consumers benefit from the defense, putting it in one shared point makes it impossible to forget.

**Why:** Defense-in-consumer means the next module that calls the unsafe thing has to remember to add its own defense, and won't. Defense-in-source means every consumer is protected by construction.

**Where applied:**
- `<think>`-tag stripping in `VLLMProvider`'s tool-call branch (Step 5.0b): every tool-call consumer gets sanitized output, not just `Kerf.LLM.Enrich`.
- `Kerf.LLM.Sanitize.strip_thinking/1` as the shared regex implementation for both text-mode (JSONParser) and tool-mode (VLLMProvider) paths.

### Pattern-of-three triggers consolidation

**Principle:** Duplication is fine for one or two instances. When a third instance appears that would copy the same pattern, that's the signal to extract. Earlier extraction is premature; later extraction means cleaning up scattered copies.

**Why:** The first instance can't be designed for reuse without knowing what reuse looks like. The second instance reveals the shape. The third confirms the pattern is real and not coincidence.

**Where applied:**
- VLLMProvider arity cleanup (deferred-work item B): trigger is "second adapter copies the workaround."
- EmailIngestor → Oban migration (deferred-work item E): trigger is "third ingestor lands."
- JSONParser `<think>`-strip consolidation (deferred-work item F): trigger is "third consumer needs the same strip."

### Extending a contract vs changing a contract

**Principle:** When modifying an existing module, distinguish between *extending* its contract (adding new return fields, new behaviors, new optional inputs) and *changing* its contract (modifying existing return shapes, removing fields, changing required inputs). Extensions are additive and require only new tests; changes break existing callers and need explicit caller migration plus updates to all dependent tests.

**Why:** Treating a contract change as if it were an extension is how live production code silently breaks downstream consumers. Treating an extension as if it were a change wastes work on unnecessary migration ceremony. Naming the distinction upfront sets the right scope for the work — and signals to reviewers what to look for (regression risk vs additive coverage).

**Where applied:**
- *Contract change:* Step 3 modified `FastClassifier.classify/2`'s return shape (`:no_match` atom → `{:no_match, %{sender_type: ...}}` tuple). 3 existing tests required in-place adjustment; the sole production caller (`Kerf.Agents.EmailTriage.EmailTriage`) needed a destructure update. The change was deliberate, scoped, and migrated in one step.
- *Contract extension:* Step 10 added `TriageRecord` write + Enricher enqueue to `Kerf.Agents.EmailTriage.EmailTriage`'s triage path without modifying its return shape. 0 existing tests required adjustment; new behavior is purely additive. New tests assert the additions; existing tests continue to assert the unchanged surface.

### Function injection over Mox for testability seams

**Principle:** When a module needs a substitutable dependency for testing, pass a function via `opts` (production-default in module attribute, override-via-opts in tests). Avoid behavior-based mocking libraries like Mox unless there's a specific reason.

**Why:** The Kerf codebase has zero Mox usage across 19+ test files; function injection is the universal pattern. Consistency beats idiomatic-elsewhere choices — every reader learns one pattern instead of two.

**Where applied:**
- `Kerf.LLM.VLLMProvider` (`:adapter` opt for Req)
- `Kerf.StructuredOutput` (`provider_fn` opt)
- `Kerf.Agents.EmailTriage.Classifier` (`provider_fn` opt)
- `Kerf.Agents.EmailTriage.Enricher` (`enrich_fn` and `record_proposal_fn` via Application config — special case because Oban can't carry function refs through JSON args; comment in module explains the seam)

---

## Testing

### Negative tests cannot prove completeness of a positive set

**Principle:** A test that asserts "garbage value X is rejected" doesn't prove that legitimate values A, B, C are accepted. To verify a validator contains the right set of allowed values, write one positive test per legitimate value.

**Why:** Three different negative tests can all pass against a validator missing one of the legitimate values — each negative case is rejected because it's not in the (now-incomplete) allowed set. Only positive tests force the validator to actually contain each expected value.

**Where applied:**
- `TriageRecord` enum-guard tests (Step 1): one positive test per `triage_status` value (`pending`, `classified`, `enriched`, `unclassifiable`), plus one negative case for "garbage rejected."

### Cast-leak detection via `cs.changes`

**Principle:** Testing an Ecto changeset's behavior with `validate_required` alone doesn't catch a missing field in the cast allowlist. To verify a field is actually being cast, assert that the field appears in `cs.changes` after applying the changeset.

**Why:** A changeset that omits `:foo` from `cast/3`'s allowlist will silently drop caller-provided `:foo` values, but `validate_required(:foo)` will pass if the underlying struct has a default. The `cs.changes.foo == "expected"` assertion catches this.

**Where applied:**
- `TriageRecord` enum-acceptance tests use this pattern to verify `put_change(:triage_status, ...)` writes to changes correctly (Step 1).

### Guardrail tests that pass-by-coincidence are still valuable

**Principle:** A test that passes against the current implementation without driving any new code is still worth keeping if it pins a contract that could regress under future refactoring. Mark such tests with a code comment explaining their guardrail purpose.

**Why:** "This test isn't doing anything" is the path to removing guardrails and discovering the regression six months later. Comments make the intentionality visible.

**Where applied:**
- Step 7's three error-propagation tests (HTTP error, `:missing_tool_call`, `:invalid_response`): all pass against the generic `{:error, _}` propagation. The comment explains they guard against future error-shape-specific handling that drops one of these atoms.

### Contract pinning depth depends on who consumes the contract

**Principle:** When a return value is consumed by code (parsed, pattern-matched, dispatched on), tests should pin the full shape exactly. When a return value is consumed only by humans (read in logs or dashboards), tests should pin the kind/prefix only.

**Why:** Over-pinning a human-consumed value constrains the implementation without test benefit — adding a context field to a log message breaks the test for no reason. Under-pinning a code-consumed value lets silent contract drift slip through.

**Where applied:**
- *Full-shape pinned (code-consumed):* `{:proposal_failed, dimension, value, reason}` rollback tuple in Step 7 — the prod-telemetry consumer parses all four fields.
- *Prefix-only pinned (human-consumed):* `RoutingConfig` validation errors in Step 8 (`elem(reason, 0) == :invalid_rule`) — errors flow to journald and dashboards, not parsing code.

### Compose Application config in tests; don't overwrite

**Principle:** When multiple test helpers manipulate the same `Application` config key, each helper must compose its changes onto the previous value (via `Keyword.put/3` or `Map.put/3`) and restore the *previous* value in `on_exit`, not the empty default. Overwriting the whole config block silently drops keys other helpers installed.

**Why:** `Application.put_env(:kerf, MyModule, [my_key: value])` replaces the entire config block for `MyModule`. If a setup block installed `[other_key: other_value]` earlier, that's now gone. Tests then fail in surprising ways — the symptom (e.g. "default behavior fires instead of injected stub") is far from the cause (an earlier test helper wiped the stub).

**Where applied:**
- `set_routing_config_name/1` in router_test.exs (Step 12): rewritten mid-Green to compose with the `:telegram_sender` key installed by the describe-level setup, after the initial implementation dropped it and broke 3 Step-9 tests.
- `set_telegram_sender/1` (Step 12): same compose-and-restore pattern from the start.
- *General rule:* if a test file installs multiple config keys on the same module, every helper that touches one of them must compose with the others.

### Describe-block `setup` for default test behavior

**Principle:** When most tests in a `describe` block need the same default behavior (e.g. a stubbed default sender to prevent real side effects), install it via a `setup` block at the describe level. Individual tests that need different behavior override locally via their own `set_*` helper.

**Why:** Inline stubs in each test that needs the default produce duplication and make "what's the baseline?" implicit. A describe-level setup makes the baseline explicit and overrides visible by contrast.

**Where applied:**
- `describe "perform/1 worker pipeline"` in router_test.exs (Step 12): installs a noop `telegram_sender` at the describe level so any test that doesn't care about delivery still runs without `{:error, :no_token}` cascading through. Tests that *do* care about delivery (e.g. "telegram_sender returning error → perform returns error") override via `set_telegram_sender/1`.

## Configuration

### `config.exs` is pre-compile; `runtime.exs` is post-compile

**Principle:** Anything in `config/config.exs` runs *before* project modules are compiled. Calling project functions from `config.exs` produces `UndefinedFunctionError` at boot — the modules aren't loaded yet. Configuration that depends on project code must live in `config/runtime.exs`, which runs after compilation.

**Why:** The symptom is far from the cause. Boot fails with "function `Kerf.X.foo/0` is undefined or private" — a misleading message that suggests the function is missing rather than the config-evaluation order being wrong. The fix is "move the config block from `config.exs` to `runtime.exs`," which isn't obvious without knowing the timing.

**Where applied:**
- Step 13's Oban cron plugin (`DigestCron.expression!/0`) lives in `runtime.exs`, not `config.exs`. The Pruner-only `:plugins` list in `config.exs` is the compile-time baseline; runtime extends it.
- *Future:* any config block that interpolates project functions (telemetry handler modules computed at runtime, dynamic queue lists from app state, etc.) must be in `runtime.exs`.

### Elixir Config replaces list values; it does not deep-merge them

**Principle:** When `runtime.exs` sets a config key that was also set in `config.exs`, scalar and map values deep-merge by key — but **list values replace wholesale**. If `config.exs` set `plugins: [A, B]` and `runtime.exs` sets `plugins: [C]`, the runtime result is `[C]`, not `[A, B, C]`.

**Why:** Silent loss of configuration. The bug doesn't surface at boot (no error, no warning) — it surfaces weeks later when someone notices a plugin isn't doing its job. By then the cause is far from the symptom.

**Where applied:**
- Step 13's Oban config: `runtime.exs` restates `Oban.Plugins.Pruner` *and* adds `Oban.Plugins.Cron`. Forgetting to restate Pruner would silently lose log-pruning in production.
- *General rule:* when extending a list-valued config key in `runtime.exs`, either restate the full list (including pre-existing entries) or build the list additively from `Application.get_env(...)` first.

### Test environment gates production-only config blocks

**Principle:** Config that depends on a runtime context unavailable in tests (real cron schedules, real Telegram tokens, real external services) should be gated behind `config_env()` checks in `runtime.exs`. Test env gets a stripped-down config without the unavailable dependencies.

**Why:** Running `mix test` shouldn't accidentally fire scheduled jobs against real systems. Gating with `if config_env() != :test do ... end` is the explicit way to express "this config is for non-test environments only." Tests use direct invocation (`Oban.Testing.perform_job/3`, manual GenServer calls) instead of the scheduled mechanism.

**Where applied:**
- Step 13's `Oban.Plugins.Cron` is gated `if config_env() != :test do ... end`. Tests exercise the worker via `perform_job/3`, never via real cron tick. `testing: :manual` in `config/test.exs` (Step 0c) prevents Oban auto-execution; the cron gate is the complementary defense for scheduled triggers.

---

## How to use this file

When closing out a build step, ask: did anything surface that's a principle for the next time we design something? If yes, add an entry here. Keep entries short — the "where applied" links to the code that demonstrates the principle in action, so the file doesn't have to re-explain everything.

If a principle stops applying (a refactor obsoletes it, or experience proves it wrong), remove the entry rather than letting it drift. The file's value is in being current, not comprehensive.
