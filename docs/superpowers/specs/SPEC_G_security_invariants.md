# SPEC_G — Security Invariants for the Governed Write Path

**Status:** Draft, 2026-09-01
**Depends on:** `THREAT_MODEL.md`, `design-notes/self-improvement-as-governed-write-path.md`
**Supersedes:** nothing. SPEC_F (model-name centralization) is independent and may land first or later.
**Owner:** Wido. Implementation: Claude Code. Planning/verification: Claude Desktop.

## 0. Ground rules for this spec

- Strict RED → GREEN. RED prompt is written from this committed spec, not from memory. RED commit is re-run independently by Wido before GREEN is authorized.
- Single-concern commits. Migrations, config, and code in separate commits.
- **Read-back first.** Several modules below are new. Before writing any RED test, Claude Code must list what actually exists in the live tree for: approval gate tables and any callers, `NotifyGuard`, `Router.handle_record`, `kb_feedback` triage rows, and any existing provenance/lineage fields. Deviations between this spec and the live tree are surfaced, not smoothed.
- Property tests use `StreamData`. Add it as a `:test` dep in its own commit if not present.

## 1. Scope

This spec introduces the minimum machinery needed to make the invariants in THREAT_MODEL.md §6–7 testable, and the tests themselves. It deliberately does **not** implement memory, skills, or the review queue from the design note. It implements the three primitives those will sit on:

1. `Kerf.Provenance` — taint type and monotone derivation.
2. `Kerf.Lineage` — append-only derivation DAG with tombstones, purge, and rollback checks.
3. `Kerf.Gate` — the only constructor of `%Kerf.Gate.Approved{}`; privileged executors require it.

Plus Phase 0, which applies to production as it is today.

## 2. Non-goals

- No review-queue UI. No budgets. No consolidation job. Those are Phase B/C of the design note and will be specified separately against these primitives.
- No changes to the credential vault or data-contract constants.
- No TLA+/Alloy in this spec (see §8).

## 3. Phase 0 — Production as-is (no new subsystems)

### G0.1 Prompt-to-invariant audit

**Deliverable:** `docs/PROMPT_INVARIANT_AUDIT.md` (private docs folder), filled from the live tree: every in-repo prompt, tool description, and skill file; every "never / always / only" sentence; the module/function that enforces it; the test that covers it. Empty enforcement cells are listed in a "Findings" section at the top. This is a read-back task, not a code task.

### G0.2 Approval gate is not optional

**Current state (from memory; verify):** `credential_vault_policies`, `approval_gate_auto_rules`, `approval_gate_log` exist and are empty; no agent path invokes the gate.

**Requirement:** any function that performs a *privileged side effect* takes a `%Kerf.Gate.Approved{}` as an explicit argument. Privileged side effects for this spec: Gmail write operations (send, label, trash), any HTTP call outside an allowlist, any credential-vault read. Telegram notify via `Router` is **not** in scope here (it is content-summarising, already guarded by `NotifyGuard`, and gating it would break production); it is re-evaluated when agents gain the ability to author Telegram text.

**RED tests:**
- `test "privileged executors do not compile / are not callable without Approved"` — compile-time where a typespec + Dialyzer can express it; otherwise a unit test asserting `FunctionClauseError` when called with a non-`Approved` first argument.
- `test "Gate.approve/2 writes an approval_gate_log row before returning Approved"`.
- `test "Approved cannot be constructed outside Kerf.Gate"` — struct has `@enforce_keys` and a private `new/…`; test asserts `%Kerf.Gate.Approved{}` literal in another module fails (compile-time test via `Code.compile_string/1` expecting an error).

### G0.3 NotifyGuard remains a hard rule under reconciliation (C6)

**RED test:** property test — generate documents with random label sets and ages; run them through the orphan reconciler path; assert no notification is emitted for any document `NotifyGuard.notify?/2` rejects, regardless of retry count or reprocessing order.

### G0.4 `ReconcileDoc` benign cancel (dead-code item from deferred work)

Unclassifiable docs return a benign cancel rather than burning retries into `discarded`. Included here because retry paths are attacker-triggerable (THREAT_MODEL §3). Single commit, existing Oban semantics.

## 4. Phase 1 — Provenance

### Module `Kerf.Provenance`

```elixir
@type taint :: :clean | :tainted
@type t :: %Kerf.Provenance{
  taint: taint,
  origin: :human | :ingress | :derived,
  sources: [artifact_id]          # empty only for :human or :ingress
}
```

- `Provenance.ingress(kind)` — `kind ∈ {:email, :document, :web, :external_skill, :tool_description}` → always `:tainted`, origin `:ingress`.
- `Provenance.human()` → `:clean`, origin `:human`.
- `Provenance.derive([%Provenance{}])` → origin `:derived`, taint = join over inputs (`:tainted` if any input is tainted), sources = union of input ids.

**Field ownership (THREAT_MODEL §5):** `Provenance` is never accepted from a proposal payload. Any envelope constructor that receives a provenance from the proposer discards it and recomputes from context. This is I1 below.

### Invariants and RED tests

**I1 — Proposer cannot set provenance, tenant, group, proposer, version_base.**
Property test: generate random envelopes where the proposal payload includes adversarial values for those fields; assert the constructed envelope's values equal the ones derived from the supplied context, never the payload's.

**I2 — Taint is monotone under derivation.**
Property test: generate random lists of provenances; `derive/1` is `:tainted` iff any input is `:tainted`. Also: `derive(derive(a) ++ b)` has the same taint as `derive(a ++ b)` (associativity — this is what closes laundering via multi-step consolidation, C1).

**I3 — Tainted artifacts cannot be a source for a skill, and cannot be auto-accepted as semantic facts.**
For this spec: `Kerf.Gate.auto_acceptable?/1` returns `false` for any envelope whose provenance is `:tainted`, for every class. Unit + property test. (Budgets that widen this are a later spec; the default is zero.)

## 5. Phase 1 — Lineage

### Module `Kerf.Lineage`

Backed by a new table `lineage_edges(child_id, parent_id, inserted_at)` and `lineage_nodes(id, kind, version, status, purged_at)` where `status ∈ {active, superseded, purged}`. **Rows are never deleted.** Purge sets `status = purged` and `purged_at`; TTL expiry of an artifact sets `status = superseded` on the node but leaves edges intact (tombstone).

API:
- `Lineage.record(child_id, parent_ids, kind, version)`
- `Lineage.descendants(id)` — transitive closure
- `Lineage.purge(id)` — marks `id` and all descendants `purged`; returns the set
- `Lineage.rollback_allowed?(artifact_id, target_version)` — false if the target version's lineage intersects any purged node

### Invariants and RED tests

**I4 — Purge is a complete transitive closure, including through tombstoned nodes (C2).**
Property test: generate random DAGs (StreamData: nodes ≤ 12, random edges, random subset marked `superseded` to simulate TTL expiry); purge a random node; assert every node reachable from it via any path is `purged`, and that nodes not reachable are untouched.

**I5 — Rollback cannot resurrect a purged lineage (C3).**
Property test: generate DAG, purge a node, pick any artifact whose earlier version descends from the purged node; assert `rollback_allowed?/2` is `false`, and `true` for versions that do not.

**I6 — Lineage rows are append-only.**
Unit test: `Repo.delete/1` on a lineage row is rejected (DB trigger or Ecto `before_delete` raising). Migration in its own commit.

**I7 — "≥3 independent trajectories" counts distinct untainted roots (C4).**
`Lineage.independent_roots(ids)` returns the set of `:human`/`:ingress`-clean roots after collapsing shared ancestry. Property test: generate trajectories that share a common tainted ancestor; assert `independent_roots` counts them as at most one, and as zero if the shared ancestor is tainted.

## 6. Phase 1 — Tenant scoping

**I8 — No query path without tenant scope.**
Kerf is single-tenant today; this invariant is cheap to add now and expensive later. Every Ecto query against `kb_*`, `lineage_*`, and `approval_gate_*` goes through `Kerf.Scope.for_tenant(query, tenant)`. RED test: a compile-time/grep test in CI that fails if any `Repo.all/one/…` call on those schemas lacks the scope call (implemented as a `mix` task; same pattern as the vocabulary parity guard). Note `email_senders` must keep the `domain != 'fast-classifier'` filter for real-correspondent queries; the scope helper must not hide that.

## 7. Phase 1 — External text as code (C7)

**I9 — Externally authored SKILL.md / tool descriptions enter through the gate with `:tainted` ingress provenance.**
Unit test: loading a skill from any path outside the repo's skills directory yields an envelope with `Provenance.ingress(:external_skill)` and `auto_acceptable?/1 == false`.

## 8. Follow-ups (not in this spec)

- **Alloy model** of `Kerf.Lineage`: nodes, edges, purged/superseded status; check I4, I5, I7 for all graphs ≤ 7 nodes. Small scope, exhaustive. Estimated one sitting.
- **TLA+ model** of gate + rollback + consolidation: three proposals in flight, purge arriving mid-consolidation; check that no state exists where an active artifact has a purged ancestor. Also one sitting once the Elixir primitives are settled.
- Review queue, budgets, consolidation job, skill registry: specified separately against these primitives (design note Phases A–C).
- Extend G0.2 to Telegram once agents can author notification text.

## 9. Acceptance

- All RED tests committed and failing, independently re-run by Wido.
- GREEN: all pass; `mix test` green; new CI guard (I8) green; Dialyzer clean on `Kerf.Gate`, `Kerf.Provenance`, `Kerf.Lineage`.
- `PROMPT_INVARIANT_AUDIT.md` committed to private docs with a Findings section, even if the section is empty.
- KERF_DEFERRED_WORK.md updated: G0.4 removed from deferred items; §8 follow-ups added.

## 10. Commit plan (suggested order)

1. `docs: add THREAT_MODEL.md and SPEC_G`
2. `test: add StreamData dev/test dependency`
3. `test(RED): Phase 0 — gate non-optional, NotifyGuard under reconciliation`
4. `feat: Kerf.Gate.Approved with private constructor; log row on approve`
5. `fix: ReconcileDoc returns benign cancel for unclassifiable docs`
6. `test(RED): Provenance I1–I3`
7. `feat: Kerf.Provenance`
8. `migration: lineage_nodes, lineage_edges (append-only trigger)`
9. `test(RED): Lineage I4–I7`
10. `feat: Kerf.Lineage`
11. `test(RED): tenant scope CI guard (I8)`
12. `feat: Kerf.Scope + mix task`
13. `test(RED)+feat: external skill ingress (I9)`
14. `docs: PROMPT_INVARIANT_AUDIT.md`
