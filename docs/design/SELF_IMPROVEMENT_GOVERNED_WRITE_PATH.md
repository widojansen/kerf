# Design Note: Self-Improvement as a Governed Write Path

**Project:** Kerf (openClaw for businesses/groups, nanoClaw security, Elixir/OTP)
**Status:** Draft, 2026-08-30
**Author:** Wido Jansen (drafted with Claude)

## 1. Thesis

"Self-improving agent" in 2026 does not mean a model retraining its own weights. It means the harness around a frozen model improves along four axes: memory (what the agent remembers), skills (reusable procedures the agent authors for itself), the outer loop (evaluate → reflect → revise prompts, routing, and skills), and data flywheels (agent traces curated into training data for the next distilled small model).

Every one of these is a *write* into state that later shapes agent behaviour. Kerf already treats the ontology as a live control plane with versioned YAML contracts, a pre-write validation gate, per-fact provenance, and a human-in-loop evolution agent. The design decision in this note is simple:

> Memory writes, skill writes, and routing/prompt revisions go through the same governed write path as ontology changes. Self-improvement is not agent autonomy; it is a proposal stream into a control plane that validates, versions, attributes, and can roll back.

This turns the main liability of self-improving agents (unreviewed drift, memory poisoning, prompt-injection persistence) into Kerf's core differentiator for business and group deployments.

## 2. What we are not doing

- No agent-authored changes to its own scaffolding or supervision tree (Darwin Gödel Machine / ADAS style). Research-grade, trust collapses, no business case yet.
- No online weight updates in production. Weight-level improvement happens offline, on a release cadence, with human curation (see §7).
- No shared global memory across tenants. Ever.

## 3. The four write classes

| Class | Example | Blast radius | Default policy |
|---|---|---|---|
| **Episodic memory** | "Supplier X sent a scanned Italian invoice; Docling failed; Tier 2 extracted correctly" | Low, per agent | Auto-accept, TTL, consolidated nightly |
| **Semantic memory / facts** | "Supplier X invoices are always scanned; route to Tier 2" | Medium, per tenant | Validate against ontology; auto-accept within policy budget; else queue |
| **Skills (SKILL.md + optional code)** | "Procedure for reconciling credit notes against original invoices" | High, per group | Always human-approved before activation; runs sandboxed |
| **Routing / prompt / threshold revisions** | "Lower Tier 1 confidence threshold for supplier X from 0.85 to 0.80" | Medium–high, per pipeline | Critic agent proposes with evidence; human approves; canary before full rollout |

All four classes share one envelope: `{proposal, evidence, provenance, tenant, group, proposer, version_base}`.

## 4. The gate

Reuse the ontology pre-write validation gate. A proposal passes through, in order:

1. **Schema validation** — the artifact conforms to its contract (memory fact schema, SKILL.md frontmatter, routing rule schema).
2. **Ontology consistency** — facts reference known entities; no contradiction with higher-provenance facts (human-stated beats agent-inferred beats agent-observed).
3. **Injection / provenance check** — the proposal's evidence chain must terminate in trusted sources. Any fact whose lineage includes untrusted external content (email body, document text, web page) is tagged `tainted` and cannot be auto-accepted, and cannot be a source for a skill.
4. **Policy budget** — per tenant and per class: how many auto-accepts per day, which classes are auto-accept at all. Budgets are part of the tenant contract, editable by the tenant admin.
5. **Human queue** — anything not auto-accepted lands in a review queue with a diff, the evidence, and a one-line rationale from the proposer.

Accepted artifacts get a version, a `derived_from` link to their evidence, and become part of the tenant's institutional knowledge base (Markdown source of truth, vector index derived).

## 5. Rollback and purge

Because every artifact has provenance, two operations are cheap:

- **Rollback**: revert a skill, fact, or routing rule to its previous version. OTP hot-reload of the skill registry; no process restart needed for the rest of the agent.
- **Purge by lineage**: if an injected instruction is discovered, purge it *and everything derived from it* in one pass. This is the operation that makes memory poisoning survivable and is the strongest security argument for provenance tracking.

## 6. Isolation boundaries (nanoClaw side)

- Memory store partitioned **per tenant, then per group**. Agents in group A cannot read group B's memory. Cross-group sharing is an explicit, approved promotion to a tenant-level library.
- Agent-authored skills execute in the **same sandbox as model-written REPL code** (existing depth=1 RLM pattern): capability grants, no ambient credentials, no network unless granted.
- Each agent's memory + active skill set lives under its own supervisor. A bad write is a crashed process that restarts from the last accepted version, not a corrupted shared file.
- Consolidation ("sleep"/lint pass) runs as a separate, lower-privilege process that can only propose merges and deletions through the gate, not apply them directly.

## 7. Data flywheel (offline)

Tier 2 escalations and human corrections are already labelled hard cases. Pipeline:

1. Collect `(input, tier1_output, tier2_output, human_correction)` tuples per tenant.
2. Nightly curation job proposes additions to the Tier 1 distillation set; same gate, same review queue.
3. Retrain Tier 1 distilled model on a release cadence; evaluate on a held-out per-tenant set; canary; promote.

Weight-level improvement therefore exists, but it is a release, not a runtime behaviour.

## 8. Phased rollout

**Phase A — Invoice flywheel (first).** Episodic + semantic memory on the invoice pipeline only. Learned per-supplier routing thresholds proposed by a critic agent, human-approved. Metrics: Tier 2 escalation rate, extraction accuracy, human review time. Bounded blast radius, measurable business value.

**Phase B — Governed skills.** Agents may propose SKILL.md artifacts from repeated successful trajectories (≥3 similar solves). Always human-approved. Skills are tenant-scoped; a tenant-level curated library is the product surface ("your organisation's institutional knowledge, on your hardware").

**Phase C — Group libraries and promotion.** Group-scoped memory/skills with explicit promotion to tenant level. Admin UI for budgets, review queue, lineage view, purge.

**Phase D (research, not committed).** Critic-agent-driven prompt/routing revision with automated canary evaluation. Only after A–C have produced enough evaluation data to make "did this change help" answerable automatically.

## 9. Open questions

- Who is the reviewer in a small Mittelstand client? Probably one designated power user per tenant plus Wido as fallback; needs a sane default when the queue goes unattended (expire proposals, never auto-accept on timeout).
- How aggressive can the auto-accept budget be for semantic facts before drift becomes noticeable? Start conservative (zero auto-accept for anything tainted; small daily budget for clean facts) and widen with evidence.
- Skill format: adopt OpenClaw's SKILL.md conventions verbatim for ecosystem compatibility, or a Kerf superset with mandatory provenance and capability fields? Leaning superset that degrades gracefully to plain SKILL.md.
- Consolidation cadence and cost on the DGX Spark alongside production inference.

## 10. One-line positioning

Kerf lets agents learn on the job, but every lesson is a reviewable, versioned, revocable artifact that stays inside the client's own walls.
