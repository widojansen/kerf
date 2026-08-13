# Spec — Triage Category Enum Fix (D11 remediation, option c)

**Status:** Draft for review
**Depends on:** d11-enum-audit-findings.md (2026-08-12, outer private docs tree — not in this repo)
**Blocks:** Phase 1 Lightning eval (commit 1 only; commit 2 is independent)
**Decision recorded:** Option (c) — add `social` to the LLM enum; remove dead `marketing` vocabulary. Rationale: `social` has real semantics and real production occurrences via the Gmail-label branch (11 rows); `marketing` has no producer anywhere (no sender rule, no Gmail branch output, no LLM pathway — 0 rows in 31,380) and is dead code.

---

## 1. Scope

Three single-concern commits, strict RED→GREEN per house rules (RED = failing tests + raising skeletons, seed-stable, committed first; GREEN = implementation only, no test edits).

- **Commit pair 1 (RED, GREEN):** add `"social"` to the LLM triage category enum in `lib/kerf/structured_output/builtins.ex` (audited location: lines 42–45; re-verify, do not trust the report's line numbers after any rebase).
- **Commit 2:** remove dead `marketing` clause heads from FastClassifier `default_priority/1` / `default_action/1` and any other `marketing` vocabulary references the audit found. Deletion-only; existing suite must stay green.
- **Commit 3 (guard):** vocabulary-parity test — assert the FastClassifier category vocabulary and the LLM schema enum are the *same set*. This is the lasting artifact: future drift fails CI instead of hiding in production for three months.

Out of scope: any change to Router routing rules, digest presentation for `social`, `validate_inclusion` on `TriageRecord.category` (deferred-work candidate, separate decision), splitting the `newsletter` blob.

## 2. Contract read-back (before RED)

Claude Code reads back, with file:line quotes:

1. The full JSON schema object sent as `response_format.json_schema` — **all** fields, not just the category enum. Open question to resolve: does the schema include a priority field, or is `final_priority` computed deterministically downstream? (Phase 1 harness design depends on the answer.)
2. Where the FastClassifier vocabulary is defined (the union sources from the audit) and where a parity test can obtain both sets programmatically. If either vocabulary is not introspectable (e.g., hard-coded clause heads), the parity test may pin both as literal lists in one place — acceptable, since the test then documents the contract even if it can't derive it.
3. What `Router.handle_record` does today with a `social`-labelled record (audit says: falls through to `default_digest` catch-all). The RED test asserts *this existing behavior*, not new routing.

Deviations from this spec are surfaced, not smoothed.

## 3. RED (commit 1a)

Failing tests:

- **T1 — schema contents:** the built triage schema's category enum equals `["business", "personal", "newsletter", "transactional", "spam", "social"]` (order per existing convention in `builtins.ex`; assert as a set if order is not meaningful).
- **T2 — end-to-end flow:** via the LLM-response seam — `Classifier.classify/2`'s `provider_fn`, injected through EmailTriage's existing `classifier_fn` option (routing verified separately via Router's real Oban seam against the shipped `priv/email_routing.exs`); corrected 2026-08-13: this spec originally misnamed `Router.handle_record` as the injection seam, which has no provider seam — a triage result with `category: "social"` from an injected provider_fn (per the VLLMProvider `&complete/3` capture gotcha: use an explicit wrapper, never the bare capture) produces a `kb_feedback` row with `decision='classified'`, `context->>'category'='social'`, and routes per the behavior confirmed in read-back §2.3.
- **T3 — negative:** a category outside the enum is impossible at the schema layer; test that the schema builder output would reject `"marketing"` (i.e., it is not in the enum after this commit — it never was; this pins the pre-commit-2 state).

Seed-stable: pass under at least two seeds before RED commit.

## 4. GREEN (commit 1b)

Add `"social"` to the enum in `builtins.ex`. No test edits. Full suite green; owner independently re-runs with multiple seeds before authorizing.

## 5. Commit 2 — dead vocabulary removal

Remove `marketing` from the `default_priority/1` / `default_action/1` clause heads and **remap** the `CATEGORY_PROMOTIONS` Gmail branch in `match_by_gmail_category/1` to `"newsletter"`, updating its test to assert `newsletter`. Production evidence (2026-08-13): 0 of 31,581 ingested documents carry the label, so no historical behavior changes; the remap is chosen over deletion so that label-bearing mail, should it ever arrive, stays fast-classified rather than falling through to the LLM. Proof obligation: full suite green, and no `"marketing"` category string survives in `lib/` or `test/`. Single commit, descriptive message referencing the D11 audit and its addendum.

## 6. Commit 3 — parity guard

One test: FastClassifier vocabulary set == LLM enum set (both = 6 values after commits 1–2). Include a comment pointing at the D11 audit so future readers know why this guard exists.

## 7. Deploy & verify

Owner deploys via the standard `deploy/deploy.sh` + `systemctl restart kerf` flow. Post-deploy verification (owner runs):

```
psql kerf_prod -Atc "SELECT context->>'category', context->>'source', count(*)
  FROM kb_feedback WHERE feedback_type='triage'
  AND inserted_at > (now() at time zone 'UTC') - interval '48 hours'
  GROUP BY 1,2 ORDER BY 3 DESC;"
```

Success signal is weak by design: `social`/`llm` rows *may* appear within days (expected rate ≈ once/week from B2 history — absence over a short soak is not failure). The hard verification is T1–T3 plus schema inspection in the vLLM request log if needed.

## 8. Eval interaction note

The golden set (v1, frozen) was labelled under the 5-value enum. During Phase 1 adjudication, a challenger label of `social` against a production label of `personal`/`newsletter` is a *legitimate potential improvement*, not automatically an error — adjudicate on merits. This is expected and is precisely why adjudication exists.
