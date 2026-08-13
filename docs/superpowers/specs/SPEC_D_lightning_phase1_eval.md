# Spec — Lightning Swap, Phase 1: Replay Harness & Side-by-Side Eval

**Status:** Draft for review
**Depends on:** Phase 0 closed (golden-set-v1.jsonl frozen, SHA cc507915…a736; baseline-cascade2-2026-08-12.md — outer private docs tree; §8 decision = local-only); enum-fix commit 1 (social in LLM enum) merged and deployed.
**Roles:** Claude Code implements the harness per this spec (commits, does not push). Owner runs all ssh/systemctl/docker/deploy operations and independently re-runs suites before phase transitions. Claude Desktop verifies outputs.

---

## 1. Purpose

Replay the frozen golden set against (A) live production Cascade 2 — validating the harness and capturing the latency baseline Phase 0 couldn't mine from history — and (C) Nemotron 3.5 Lightning on a new vLLM container (B), scoring both against the *same corrected 6-value schema*, with human adjudication of disagreements producing Kerf's first ground-truth overrides file.

## 2. Design decision: the harness lives inside Kerf

The harness is a mix task (`mix kerf.eval.replay`) that classifies each golden-set email through **the production code path** — the real prompt template and the real StructuredOutput builtins schema — against a configurable endpoint URL. Rationale: schema/prompt parity with production is guaranteed by construction, not by copy-paste; and the enum fix automatically applies to both models. A standalone script would have to re-implement the prompt and would drift.

Constraints:
- Read-only with respect to production state: the harness must **not** write `kb_feedback` rows, must not enqueue Oban jobs, must not touch the Router. It calls the classification function at the provider seam only (explicit wrapper, not the `&complete/3` capture) and writes results to a JSONL file.
- Runs on the Spark from the deployed checkout or via `mix` in a source checkout — owner's choice; must not require the BEAM to read outside its permitted paths (input/output under a path the task receives as an argument; if running under `kerf.service` restrictions ever becomes relevant, stage under `/opt/kerf/` — but the intended mode is an interactive `mix` run from the owner's shell, where `ProtectHome` does not apply).
- CLI contract: `mix kerf.eval.replay --input <golden.jsonl> --output <results.jsonl> --endpoint <url> --model <served-model-name> --tag <run-tag> [--thinking on|off] [--temperature T --top-p P] [--limit N]`.
- Per-email output record: `doc_id`, `run_tag`, `category_out`, full raw response, schema-valid boolean, wall-clock latency ms, token counts if the API returns usage, error field on failure. One JSONL line per email; partial-failure tolerant (a failed email records an error and the run continues).
- Determinism note: model outputs at temp > 0 are not deterministic; the harness records exact sampling params in a run-manifest header line so every run is reproducible-in-configuration even when not in output.

## 3. Contract read-back (before RED)

1. Confirm the classification entry point that takes (email content, provider_fn) and returns the parsed structured result — the seam the harness calls. Quote it.
2. Confirm from the enum-fix read-back whether the schema includes a priority field. If **yes**: the harness records it and priority agreement joins scoring (§7). If **no** (priority is deterministic downstream): priority is out of scope for the harness — category agreement subsumes it.
3. Confirm how the current provider selects reasoning behavior (Cascade emits `</think>` always; Lightning takes `chat_template_kwargs.enable_thinking`). The harness needs a per-run switch that is a no-op for Cascade and sets the kwarg for Lightning.

## 4. Stage A — Cascade 2 validation run (production endpoint, existing vllm.service)

Owner runs, from a source checkout on the Spark:

- Run A1: full 241 emails, production sampling settings, `--tag cascade2-prod-settings`.
- Run A2 (optional but cheap): repeat identical config, `--tag cascade2-repeat` — the pairwise self-agreement between A1 and A2 measures Cascade's label stability, a baseline quality signal no history query could give us.

Acceptance for Stage A (validates the harness itself):
- ≥ 99% schema-valid responses (Cascade against its own production schema+prompt should be near-perfect; below that, suspect the harness).
- fc_control stratum: ≥ 90% agreement with production labels (these were FastClassifier-labelled, so this checks the model agrees with high-confidence embedding matches — the §7 control).
- llm_fallback stratum: agreement with production labels here measures *self-consistency* (same model, same email, later date). Record it; expect high but not 100%. This number contextualizes Lightning's disagreement rate — Lightning disagreeing with Cascade at roughly Cascade's own self-disagreement rate is noise, not signal.
- Latency: p50/p95/p99 wall-clock per email → this **is** the §6.3 latency baseline; append to baseline-cascade2-2026-08-12.md.

## 5. Stage B — Lightning container verification (owner-run spikes, no Kerf changes)

Ordered so the cheapest blocker fires first. All commands owner-run; Claude Desktop supplies exact command lines when reached.

- **B1 — image availability (blocks everything):** does `vllm/vllm-openai:v0.27.1` (or the equivalent nvcr.io 26.xx release) exist for aarch64 and start on GB10? Verify with `docker manifest inspect` before any pull. Record which image wins.
- **B2 — model boot:** Lightning NVFP4 + DSpark checkpoints pulled; container starts with the model-card Spark recipe **amended**: `--max-model-len 131072` (not the 1M default — headroom for side-by-side), second port (8001), `--gpu-memory-utilization` tuned down from 0.91 as needed to coexist with production Cascade (start at 0.45 and raise; if coexistence fails, fall back to scheduled-downtime alternation and note it). Record startup-to-ready time vs the ~7–8 min Cascade expectation.
- **B3 — structured output:** one manual curl with the production schema as `response_format: json_schema, strict: true`; confirm enforcement (guided decoding) rather than silent ignore. This was the 0.15.1 trap; do not assume 0.27.x behaves, verify.
- **B4 — parser sanity:** `--reasoning-parser nemotron_v3`, `--tool-call-parser qwen3_coder` accepted; a thinking-off request returns clean content with no `</think>` residue.

Exit: all four green, or a written blocker note (B1 failure → hunt nvcr alternatives before declaring Phase 1 blocked).

## 6. Stage C — Lightning eval runs

- Run C1 (primary, the intended production config): full 241, `--thinking off`, temp 1.0 / top-p 0.95 per model card, `--tag lightning-thinking-off`.
- Run C2 (quality-delta probe): 50-email subset — the llm_fallback emails where C1 disagreed with production, topped up randomly to 50 — `--thinking on`, `--tag lightning-thinking-on`. Answers: does thinking buy accuracy worth its latency on exactly the hard cases?
- Run C3 (optional, only if C1 shows label instability concerns): C1 config repeated, self-agreement check mirroring A2.

## 7. Scoring & adjudication (protocol frozen in Phase 0, amended per D11)

- **Primary:** C1 category agreement with production labels on llm_fallback (n=200), overall + per-label. Reported alongside Cascade's A1↔A2 self-agreement for context.
- **Adjudication:** every C1↔production disagreement gets an owner ruling; rulings append to `~/eval/golden-overrides.jsonl` (`doc_id`, `label_true`, `note`), which becomes the ground-truth layer. Post-adjudication, report **adjudicated accuracy** for both models — this, not raw agreement, is the decision metric. Expected volume: elevated by the enum fix (challenger may legitimately say `social`); budget for 40–80 rulings.
- **Guardrails:** schema-validity ≥ Stage A's Cascade rate; fc_control ≥ 90%; social_probe reported descriptively (n=11, no threshold).
- **Latency:** C1 p50/p95/p99 vs Stage A baseline. Not a gate, but the headline expected win; if Lightning is *slower* despite DSpark, that's a finding to investigate before cutover.
- **Goalpost rule:** any metric change after C1 output exists requires written justification in the run notes.

## 8. Decision gate (Phase 1 exit → Phase 2 integration)

**Go** if: adjudicated accuracy ≥ Cascade's, guardrails met, and no Stage B stability incidents during the runs (vllm container crashes, OOM, mamba-backend errors in its journal). **No-go / defer** otherwise, with the results file as the evidence either way. A marginal-accuracy + large-latency-win outcome is a judgment call the numbers inform but the owner makes.

## 9. Deliverables

- Harness: `lib/mix/tasks/kerf.eval.replay.ex` + tests (RED→GREEN; tests exercise JSONL parsing, output record shape, error tolerance, and the seam call via injected provider_fn — **no live endpoint in tests**).
- `~/eval/results-*.jsonl` per run (PII: bodies echoed in raw responses — same handling as the golden set, never in a repo).
- `~/eval/golden-overrides.jsonl` (adjudications; contains subjects at most — still keep out of repos).
- `docs/specs/phase1-results-<date>.md` — the comparison report, numbers only, repo-safe; feeds the Phase 2 go/no-go.
