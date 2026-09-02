# Kerf Threat Model

**Status:** Draft, 2026-09-01
**Companion to:** `design-notes/self-improvement-as-governed-write-path.md`, `SPEC_G_security_invariants.md`
**Author:** Wido Jansen (drafted with Claude)

## 1. Why this document exists

Testing shows that bugs exist; it never shows they are absent. The dangerous failures in a system like Kerf are not implementation slips but compositions of individually harmless design choices (see the UDS ISO 14229-1:2020 analysis: two minor omissions, one complete authentication bypass). Those failures live in the protocol — the messages, who may set which field, what each party trusts — before any code exists.

For an agent platform there is a second reason. A large share of Kerf's behaviour is specified in text the model reads (system prompts, tool descriptions, SKILL.md files, retrieved context). None of that text is enforceable. This document therefore defines an attacker model in which the model itself is compromised, and lists the properties that the deterministic OTP layer must guarantee regardless of what the model does.

Design rule that follows from this:

> **Text is the request. Code is the protocol.** Any sentence in a prompt of the form "never / always / only" is an intent, not a control. Every such sentence must map to a deterministic enforcement point, or it is a documented gap.

## 2. Actors

| Actor | Trust level | Notes |
|---|---|---|
| Wido / tenant admin | Trusted (human) | Approves queue items, edits budgets, runs deploys |
| Deterministic OTP layer (`Kerf.Router`, `NotifyGuard`, Oban workers, gate, lineage store) | Trusted | The only place invariants may be enforced |
| PostgreSQL, OTP process boundaries, AES-256-GCM vault, Telegram/Google auth | Trusted primitives | Assumed unbreakable (symbolic-model assumption) |
| LLM (vLLM / Lightning, any future model) | **Untrusted** | Modelled as a compromised component: has read all prompts, may emit any output or tool call |
| Agents built on the LLM (critic agent, consolidation pass, skill proposer) | **Untrusted** | Inherit the model's trust level; may propose, never apply |
| Email bodies, attachments, documents, web pages, search results | **Attacker-controlled** | Every byte may be an injected instruction |
| Third-party SKILL.md, MCP tool descriptions, plugins not authored in-repo | **Attacker-controlled** | Executed as instructions; treated as supply-chain input |
| Other tenants / groups | Attacker (for isolation purposes) | Never share memory |

## 3. Attacker capabilities

The attacker can:

- Author any content that Kerf ingests (email, document, web, tool description).
- Cause the model to emit any output, including well-formed proposals, tool calls, and plausible rationales.
- Cause the model to set any field it is *allowed* to set in any envelope or tool argument.
- Trigger retries, reprocessing, and reconciliation paths by making inputs fail in chosen ways.
- Wait: poison written today may only be exploited after consolidation, TTL expiry, or rollback.

The attacker cannot:

- Read or write PostgreSQL except through Kerf code paths.
- Cross an OTP process or supervisor boundary.
- Forge Telegram or Google credentials, or decrypt the credential vault.
- Modify code, config, or in-repo prompt files (those are Wido's release artifacts).

## 4. Assets

1. **Outbound side effects**: Telegram messages, Gmail sends/labels, HTTP calls, credential use.
2. **Institutional knowledge**: semantic facts, skills, routing/threshold rules (the artifacts that shape future behaviour).
3. **Tenant/group isolation**.
4. **Credential vault** and the data-contract constants that guard it.
5. **Auditability**: the ability to answer "why did the system do X" and "purge everything derived from Y".

## 5. Trust boundaries and who may set what

The governed-write-path envelope is `{proposal, evidence, provenance, tenant, group, proposer, version_base}`. Field ownership:

| Field | Set by | Never settable by |
|---|---|---|
| `proposal`, `evidence` | Proposer (untrusted) | — |
| `provenance` / taint | Deterministic ingress code, from the process context and the evidence lineage | Proposer |
| `tenant`, `group` | Deterministic layer, from supervisor/process context | Proposer |
| `proposer` | Deterministic layer | Proposer |
| `version_base` | Deterministic layer (read from the store) | Proposer |

Rationale: if the proposer could set `provenance`, an attacker reaching the model could declare its own evidence clean. This is the direct analogue of UDS flaw 1 (negotiation parameters outside the signed data).

## 6. Composition risks identified

Each is a pair of individually reasonable behaviours that combine into a failure. These are the cases the invariants in SPEC_G exist to close.

| # | Behaviour A | Behaviour B | Combined failure |
|---|---|---|---|
| C1 | Episodic memory auto-accepts (low blast radius) | Nightly consolidation derives semantic facts from episodic | Tainted episodic content is laundered into a "clean" semantic fact if taint does not propagate through consolidation |
| C2 | Episodic memory has TTL | Purge-by-lineage walks from the root | Root expires before poison is found; descendants become orphans that purge cannot reach |
| C3 | Rollback restores a previous version | Purge removes a lineage | Rollback to a version derived from a purged node resurrects the poison |
| C4 | Skills proposed after ≥3 similar successful trajectories | Trajectories share evidence | Three solves influenced by one injected email count as three independent successes |
| C5 | Approval gate exists (`approval_gate_*` tables) | No code path is required to call it | The insecure minimal configuration is the default; the system works with the gate bypassed (analogue of UDS permitting the weak auth profile) |
| C6 | Orphan reconciler re-triages stranded documents | Triage produces notifications | Reprocessing re-emits side effects for content that was already handled or was aged out (currently mitigated by `NotifyGuard`; must remain a hard rule) |
| C7 | Third-party SKILL.md adopted for compatibility | Skills execute in the RLM sandbox | Externally authored instructions run with whatever grants the sandbox has, without passing the gate as agent-authored skills must |
| C8 | Model name / thresholds hardcoded in several places | Config intended to be central | Documented configuration ≠ actual behaviour; a security-relevant setting (threshold, allowed category) can be silently stale |

## 7. Enforcement principle

Invariants are enforced structurally where possible:

- Authority is a value, not a check. Privileged executors accept only an `%Approved{}` struct whose constructor is private to the gate module. Without an approval, the call does not typecheck.
- Taint is a type, not a flag the model can flip. Derivation computes taint as the join over all inputs.
- Lineage is append-only with tombstones; nothing is ever hard-deleted from the lineage table, only from the artifact tables.

Where structure is not enough, invariants are checked by property-based tests over generated derivation graphs and event sequences (SPEC_G), and — as a follow-up — by a bounded Alloy model of the lineage graph and a TLA+ model of gate/rollback/consolidation ordering.

## 8. Explicit non-goals

- Proving properties about model output quality. The model is untrusted; nothing here depends on it behaving.
- Defending against a compromised host, database, or Wido's own credentials.
- Multi-tenant isolation beyond what OTP + Postgres row scoping can give. No shared global memory, ever, is the design rule; this document does not weaken it.

## 9. Prompt-to-invariant audit

Every in-repo prompt, tool description and SKILL.md is to be audited against the table below. A row with an empty *Enforced by* column is a finding.

| Source file | Instruction ("never/always/only" sentence) | Enforced by (module/function) | Test |
|---|---|---|---|
| *(fill from live tree)* | | | |

Known filled rows at time of writing:

| Source | Instruction | Enforced by | Test |
|---|---|---|---|
| Classifier prompt | Output only categories from the enum | `response_format: json_schema, strict: true`; vocabulary parity guard in CI | CI guard |
| Router / Telegram | Do not notify on SENT-label mail or mail older than the window | `NotifyGuard.notify?/2` at the Router seam | existing NotifyGuard tests |

The audit is a deliverable of SPEC_G Phase 0.
