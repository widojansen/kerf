# SPEC_H steps 2–3 — Decide eval: labelled set (F08) and harness (F09)

> Repo copy (lead-owned): `docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md`.
> Task 0 (public `CLAUDE.md`) is done by the owner: commit 4deffd3; private import verified
> 2026-10-20 (a line present only in the private file is loaded in-session).
>
> **For agentic workers:** each task is a RED commit and a GREEN commit in the executor's own
> worktree, gated by the lead and authorized by the owner (see "Gate procedure"). Executors never
> edit files outside their owner block. Steps use `- [ ]` checkboxes.

**Goal:** Produce the labelled NL/DE/EN mail set with its validated manifest (F08) and a
deterministic `mix kerf.eval.decide` harness whose gates are proven against a random and an oracle
adapter (F09.9) before any real model is run.

**Architecture:** One loader (`Kerf.Eval.Manifest`) owns the manifest schema; the LiveDashboard
labelling page writes labels only through it, the harness reads items only through it. The harness
asks every question through `Kerf.Decide.ask/3` so validation, OptionSet handling and provenance are
exercised as in production (SPEC_D §2 precedent: harness inside Kerf, read-only w.r.t. production
state). Scoring is pure Elixir over the run JSONL; no Nx, no Python.

**Tech stack:** Elixir 1.20.1/OTP 28, Jason (`Jason.OrderedObject` for deterministic key order),
Phoenix LiveDashboard `PageBuilder` (existing dashboard pattern), StreamData (already a test dep),
`:rand` with `:exsss` seeds, `ssh spark` + `psql` for the export (read-only).

**Spec:** `docs/superpowers/specs/SPEC_H_kerf_decide.json` F08, F09 + `SPEC_H_addendum_01.json`
(A1.4 result shapes, A1.9 category enum, F08.7 note) + `SPEC_H_addendum_02.json` (A2.1 state_hash
deferred to step 5, "next" block). The spec and its addenda are the contract.

---

## 1. Scope and non-goals

**In scope (acceptance checks this plan closes):**

| Feature | Checks | Notes |
|---|---|---|
| F08 | F08.1 counts + mix recorded and loader-checked; F08.2 question-set labels validated by loader; F08.3 pairs validated; F08.4 tier-before-run enforced by loader; F08.5 held-out split + training export refusal; F08.6 PII guard test; F08.7 overrides seeding + `adjudicated`/`new` per item | Labelling itself is the owner's (handoff H-1) |
| F09 | F09.1 accuracy per tier/language + gate; F09.2 ECE raw + temperature-scaled; F09.3 flip rate; F09.4 isolation probe + packed/separate; F09.5 latency p50/p95 recorded; F09.6 coverage; F09.7 contrastive; F09.8 determinism; F09.9 validate-the-validator | Real-model runs (F09.5 on M5/GB10) are F10 |

**Non-goals:** F10 (baselines, DECISION_FAMILY.md), F04 (vLLM logit adapter — step 3 host GB10,
owner-sequenced separately), F07 (drift worker), F11, fine-tuning. Where they plug in:

- F10 runs `mix kerf.eval.decide run --adapter http --base-url …` per baseline and `score`; it
  cites the report files by path + sha256 (the `score` subcommand prints the report's sha256).
- F04 plugs in as `--adapter Elixir.Kerf.Decide.Adapter.VLLM` — no harness change.
- F07.3 reads `report.json → histograms[question_name]` (10 bins, see §2.4).
- F09.2's fitted temperature is emitted as an artefact (`temperatures.json`); wiring it into an
  adapter config is F10/F11 (Status entry S-6).

---

## 2. Interfaces — fixed before any executor starts

### 2.1 `Kerf.Eval.Manifest` (owner: kerf-eval-data; consumers: UI, harness)

Files: `lib/kerf/eval/manifest.ex`, `lib/kerf/eval/manifest/item.ex`.

```elixir
%Kerf.Eval.Manifest{
  schema_version: 1,
  set_id: String.t(),                      # "decide-v1"
  created_at: String.t(),                  # ISO8601 UTC "2026-10-21T09:00:00Z" (all timestamps)
  frozen_at: String.t() | nil,             # set by freeze/4; nil = still labelling
  export: %{host: String.t(), exported_at: String.t(), query_sha256: String.t(),
            overrides_sha256: String.t() | nil, row_count: non_neg_integer(),
            mix_shortfall_acknowledged: boolean()},
  question_set: %{String.t() => question_def},   # plain map; keys == QuestionSet.order/0 exactly. ORDER IS NOT IN THE MAP (S-16): every consumer iterates QuestionSet.order/0
  counts: %{total: n, labelled: n, tiered: n, held_out: n, pairs: n,
            by_language: %{String.t() => n}, by_tier: %{String.t() => n}},  # recomputed on save, re-checked on load (F08.1).
            # total INCLUDES synthetic pair items; pairs = number of pairs = number of synthetic b-items;
            # real items = total − pairs, and that is what the freeze "≥ 200" threshold counts (S-17)
  items: [%Kerf.Eval.Manifest.Item{}]
}

# question_def (strings, JSON-shaped; harness builds Kerf.Decide questions from it):
# %{"type" => "choice", "instructions" => s, "options" => [labels in caller order]}
# %{"type" => "noul",   "instructions" => s}
# %{"type" => "score",  "instructions" => s, "levels" => ["1","2","3","4","5"]}
# Phase B keys, in the order QuestionSet.order/0 returns them: "category" (options = SPEC_C
# 6-enum, A1.9), "needs_reply", "urgency", "deadline_present", "client" (options = clients ++ ["none"]).
# An Elixir map and a decoded JSON object do not preserve this order (S-16 ruling: option (b)).

%Kerf.Eval.Manifest.Item{
  id: String.t(),                          # "it-0001", unique, stable
  doc_id: String.t() | nil,                # kb_documents.id; nil for synthetic pair items
  source_id: String.t() | nil,             # kb_documents.source_id (unique with source_type); nil for synthetic pair items (owner addition 2026-10-21 at D2 RED go; Synthetic real items "src-<n>")
  seed_category: String.t() | nil,         # F08.7 override value carried until the owner labels; labels stay nil (S-29, D2)
  synthetic_of: String.t() | nil,          # item id this synthetic item was edited from
  language: "nl" | "de" | "en" | "und",
  language_source: "heuristic" | "human",
  state: %{from: s, from_name: s | nil, subject: s, date: s, body: s},   # PII — private tree only
  labels: nil | %{"category" => s, "needs_reply" => boolean, "urgency" => 1..5,
                  "deadline_present" => boolean, "client" => s},
  label_sources: %{"category" => "adjudicated" | "new"},  # F08.7; only category carries a source
  labelled_at: s | nil, labelled_by: s | nil,            # "wido"
  tier: nil | "easy" | "standard" | "hard", tier_reason: s | nil, tiered_at: s | nil,  # F08.4
  split: nil | "eval" | "calibration",     # nil until frozen; assigned by freeze/4 (F08.5)
  pair_id: s | nil, pair_fact: s | nil     # F08.3: both items of a pair share pair_id
}
```

Public functions (all `@spec`'d; errors are `{:error, [violation]}` with
`violation :: {code :: atom(), item_id :: String.t() | nil, detail :: term()}`; never raise):

```elixir
load(path)                    :: {:ok, t} | {:error, [violation]}   # decode + validate/1
validate(t)                   :: :ok | {:error, [violation]}
save(t, path)                 :: :ok | {:error, term}  # validate (shape; incompleteness allowed pre-freeze), recompute counts, write tmp + rename
put_label(t, item_id, labels, now)        :: {:ok, t} | {:error, [violation]}  # checks against question_set; sets labelled_at and labelled_by = @labelled_by "wido" (module constant, S-19), label_sources["category"] = "new" unless already "adjudicated"
put_tier(t, item_id, tier, reason, now)   :: {:ok, t} | {:error, [violation]}  # reason non-blank
put_language(t, item_id, lang)            :: {:ok, t} | {:error, [violation]}  # language_source "human"
add_synthetic_item(t, of_item_id, state, now) :: {:ok, {t, item_id}}
mark_pair(t, pair_id, item_a, item_b, fact)   :: {:ok, t} | {:error, [violation]}
freeze(t, seed, now, opts)    :: {:ok, t} | {:error, [violation]}  # see rules; calls assign_split/3 with n = 50
assign_split(t, n, seed)      :: t   # pure (S-17/S-18): marks exactly n eligible (non-pair) items "calibration", stratified by (language, tier) over the ELIGIBLE pool, quota_s = n · n_s / N_eligible with largest-remainder rounding (each stratum ∈ {⌊quota_s⌋, ⌈quota_s⌉}), chosen by :rand.seed(:exsss, {seed, 0, 0}) over items sorted by id; every other item "eval". Shared by freeze/4 and Synthetic.build/1.
items(t, :eval | :calibration) :: {:ok, [Item]} | {:error, :not_frozen}
training_export(t)            :: {:ok, [Item]} | {:error, :not_frozen}  # NEVER contains split == "calibration" (F08.5)
ready_for_run?(t)             :: :ok | {:error, violation}   # frozen AND every tiered_at <= frozen_at AND counts match (F08.4)
sha256(path)                  :: {:ok, String.t()} | {:error, term()}  # lowercase hex of file bytes on success (run header); {:error, reason} on an unreadable path — never raises (owner change 2026-10-20, S-23b)
```

Validation codes (minimum): `:duplicate_item_id`, `:duplicate_doc_id` (compares non-nil `doc_id`
only — synthetic pair items all carry `doc_id: nil` and must not collide), `:unknown_question`,
`:missing_question_label`, `:label_not_in_options`, `:label_wrong_type` (e.g. `"3"` for urgency,
`"true"` for a Noul — JSON round-trip strings are rejected, not coerced), `:urgency_out_of_range`,
`:empty_body`, `:empty_tier_reason`, `:pair_incomplete` (≠ 2 items), `:pair_no_flip` (no label
differs), `:pair_fact_blank`, `:counts_mismatch`, `:language_invalid`, `:unknown_label_source`,
`:question_set_keys` (keys ≠ `QuestionSet.order/0` as a set), `:frozen` (any mutation —
`put_label/4`, `put_tier/5`, `put_language/3`, `add_synthetic_item/4`, `mark_pair/5` — or a second
`freeze/4` on a manifest whose `frozen_at` is set: `{:error, [{:frozen, item_id | nil, _} | _]}`,
manifest unchanged; owner amendment to D1 RED, 2026-10-20, F08.4/F08.5), `:question_def_invalid`
(manifest-level, emitted once before any per-item check, `{:question_def_invalid, nil,
{question_key, reason}}` with reason `:options_not_list` / `:levels_not_list` / …; heads the
violation list; the per-item `:unknown_question_type` is not emitted for such a manifest — D1b, S-26).

Freeze rules (`freeze/4`): refuses unless every item has `labels` and `tier`; ≥ 200 **real** items
(`counts.total − counts.pairs`, i.e. `doc_id` non-nil — F08.1 counts exported mails; synthetic pair
items do not count);
`pairs >= 20` each with ≥ 1 flipped label; language mix NL ≥ 0.40, DE ≥ 0.25, EN ≥ 0.20 of `total`
unless `opts[:allow_mix_shortfall]` (then `export.mix_shortfall_acknowledged = true`, Status S-9).
Then `assign_split(t, 50, seed)` (pair items are never calibration; both stay `"eval"`) and sets
`frozen_at = now`.

Companion modules (same owner): `Kerf.Eval.Manifest.Synthetic.build(opts) :: t` (seeded; defaults
`n: 220, pairs: 24, seed: 1, frozen: true`; addresses `user<n>@example.invalid`; client names
`"client-a".."client-c"`; the only manifest tests and the harness self-test ever use).
Size semantics (binding for D1, D4, H3, H4): `n` is the number of **real** items (`doc_id` set);
`pairs` **appends** that many **synthetic** b-items (`doc_id: nil`, `synthetic_of` = a real item,
same language, one label flipped), so a build has `n + pairs` items: `build()` = 244 items, 220
real, 196 eligible (non-pair); `n: 8, pairs: 2` = 10 items; `n: 12, pairs: 2` = 14; `n: 60, pairs: 6`
= 66. S-17 ruling: `Synthetic` does **not** go through the freeze thresholds; it labels and tiers
every item, then calls `assign_split(t, n_cal, seed)` with
`n_cal = if real >= 200, do: 50, else: max(1, round(0.2 * eligible))`, and sets `frozen_at`
(`n: 8, pairs: 2` → 1 calibration item). With `frozen: false` it returns the same manifest unfrozen;
the default size (220/24, language mix met) passed through `freeze/4` must succeed and yield the
identical split — both paths call `assign_split(t, 50, seed)` — which keeps the real freeze path
exercised.
`Kerf.Eval.Manifest.QuestionSet.order/0 :: ["category", "needs_reply", "urgency", "deadline_present", "client"]`
(S-16: the single source of question order; `validate/1` requires `question_set` keys == this list
as a set, code `:question_set_keys`),
`Kerf.Eval.Manifest.Language.guess(text) :: "nl" | "de" | "en" | "und"` (stopword ratio),
`Kerf.Eval.Manifest.Overrides.load(path) :: {:ok, %{doc_id => category}} | {:error, term}`
(line shape per SPEC_D §7: `doc_id`, `label_true`, `note`; `label_true` ∉ 6-enum is an error),
`Kerf.Eval.Manifest.QuestionSet.phase_b(clients :: [String.t()]) :: question_set` (the Phase B
instruction strings live here, once; F11 reuses them later),
`Kerf.Eval.Manifest.PII` (§2.5).

### 2.2 `manifest.json`

JSON encoding of the struct above with `schema_version`, string keys, item fields as listed, item
order preserved, written atomically. Location: Spark `~/eval/decide/manifest.json`; Mac
`~/Projects/kerf/private/eval/decide/manifest.json` (Status S-1). Never inside the repo.

### 2.3 Harness run JSONL (owner: kerf-eval-harness; reader: scorer, F07.3 via the report)

File `lib/kerf/eval/harness/run.ex`. Line 1 header, then one line per answer, last line `run_end`.

```json
{"type":"run_manifest","schema_version":1,"run_id":"<set_id>-<adapter-short>-s<seed>-<started_at>",
 "set_id":"decide-v1","manifest_path":"…","manifest_sha256":"…","manifest_frozen_at":"…",
 "adapter":"Kerf.Decide.Adapter.HTTP","adapter_opts":{"base_url":"http://127.0.0.1:8900"},
 "info":{"model_id":"…","types":["noul","choice","score"],"max_state_tokens":8192,"languages":["nl","de","en"]},
 "seed":1,"permutations":6,"isolation_items":30,"limit":null,"latency_skipped":false,
 "host":"<hostname>","kerf_git_sha":"<short sha>","started_at":"2026-10-22T10:00:00Z"}

{"type":"answer","item_id":"it-0001","doc_id":"…","language":"nl","tier":"easy","split":"eval","pair_id":null,
 "question":"category","qtype":"choice","probe":"main","packed":true,"order_index":0,
 "order":["business","personal","newsletter","transactional","spam","social"],
 "gold":"business",
 "result":{"label":"business","probs":[["business",0.91],["personal",0.02],…],"confidence":0.892},
 "latency_ms":12,"error":null}

{"type":"run_end","finished_at":"…","answers":7700,"errors":0}
```

- `probe` ∈ `"main"` (packed 5-question request, one per `order_index` 0..5), `"separate"`
  (one request per question, identity order, `packed:false`), `"isolation_sibling"`,
  `"isolation_state"` (question `"secret_present"`, `qtype:"noul"`, gold `false`/`true`).
- `order` is the option list sent for a Choice question in that request; `null` for Noul/Score.
  `order_index 0` is identity (manifest order); 1..5 are a functional Fisher–Yates over
  `:rand.uniform_s/2` with the state from `:rand.seed_s(:exsss, {seed, item_index * 64 + question_index, order_index})`
  threaded through (S-22/H1b; the 3-tuple of A3.11 — `:rand.seed_s/2` rejects a 4-tuple; `question_index < 64` always).
- `result` keys by `qtype`: noul `{p_yes}`, choice `{label, probs, confidence}`, score
  `{expected, probs, confidence}` — exactly `Kerf.Decide.Result` minus `backend/latency_ms/provenance`.
  On adapter error: `result: null`, `error: inspect(reason)`, the run continues (F09.6 then fails).
- `latency_ms` is the request latency from the result; identical for all lines of one request.
- Lines are written in deterministic order: items in manifest order → probes (main orders 0..5,
  separate, isolation) → questions in `Kerf.Eval.Manifest.QuestionSet.order/0` order (S-16; the
  harness's `Questions` module carries the same fixed list and H3's RED asserts the two are equal).
- `Run.normalize/1` drops `latency_ms`, `started_at`, `finished_at`, `run_id` — F09.8 compares
  normalized files byte-for-byte.

### 2.4 Report JSON (`Kerf.Eval.Harness.Report`)

Keys sorted recursively (`Jason.OrderedObject`) so two reports are byte-identical:
`accuracy, contrastive, coverage, ece, flip_rate, gates, histograms, isolation, latency, run, schema_version, temperature`.

- `gates`: `%{"F09.1" => %{status: "pass"|"fail"|"skipped"|"pending", value, threshold, detail}, … "F09.7"}`.
- `accuracy[question] = %{overall, by_tier: %{tier => acc}, by_language: %{lang => acc}, n}` on
  eval split, `probe "main"`, `order_index 0`. Predicted label: choice `label`; noul `p_yes >= 0.5`;
  score `levels[round(expected)]`.
- `ece[question] = %{raw, scaled, n}` for noul/choice only (10 equal-width bins, edge rule
  `bin = min(trunc(p * 10), 9)`; confidence `p` = `p_yes` for noul, `p_max` for choice; `ECE = Σ n_b/N · |acc_b − conf_b|`).
- `temperature[question] = T` fitted on the **calibration split only** by minimizing NLL of
  `softmax(log(p_i + 1.0e-12) / T)` (noul as 2-class `[p, 1-p]`) with golden-section search on
  `log T ∈ [-4, 4]`, 100 iterations. `scaled` ECE is on the eval split after applying `T`.
- `flip_rate = %{overall, by_tier, by_question}`: for each Choice (item, question), flips =
  count of `order_index 1..5` whose `label` ≠ order-0 label; rate = flips / (pairs counted).
- `isolation = %{sibling_mean_p_yes, state_mean_p_yes, packed_separate_agreement, n}`.
- `latency = %{p50_ms, p95_ms, n} | null` over `probe "main"`, `order_index 0` requests.
- `coverage = %{expected, answered, errors, in_schema}`; gate 100 %.
- `contrastive = %{pairs, passed, rate}`: a pair passes when, for every question whose gold differs
  between its two items, both predictions equal their gold.
- `histograms[question] = %{model_id, bins: [10 counts], n}` of the F09.2 confidence on eval
  split, identity order — the F07.3 baseline.
- Gate thresholds (spec values, revisable only by addendum): F09.1 category easy ≥ 0.90 and
  category overall ≥ `baseline_accuracy` (pending when nil); F09.2 scaled ECE ≤ 0.08 on every
  noul/choice question; F09.3 overall ≤ 0.05 and hard ≤ 0.10; F09.4 sibling ≤ 0.10, state ≥ 0.90,
  agreement ≥ 0.98; F09.5 p95 ≤ 150 ms (`--host-class decoder`) or ≤ 30 ms (`encoder`), skipped
  when `latency_skipped`; F09.6 100 %; F09.7 ≥ 0.85.

### 2.5 PII guard artefact (owner: kerf-eval-data)

The address-hash list is **not committed** (A3.7: unsalted SHA-256 of addresses in a public repo is a
membership oracle over the owner's correspondents; `priv/eval/` is not created). It lives at
`~/Projects/kerf/private/eval/decide/address_hashes.txt`, written by `mix kerf.eval.export
--hashes-out`: one lowercase hex SHA-256 per line of each downcased, trimmed address in the set
(`from` of every real item), sorted, header line `# sha256 of addresses in the decide set`.
`test/eval/pii_guard_test.exs` is tagged `@moduletag :pii_guard`, reads the list path from the
`KERF_EVAL_HASHES` environment variable, extracts `~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/`
tokens from every file under `docs/superpowers/specs/`, `docs/superpowers/plans/`, `test/`, `lib/`,
hashes them and asserts none is in the list. When the variable is unset the test is **skipped with a
printed notice** (`IO.puts` naming the variable, then `ExUnit` skip), never silently green. The
lead's gate runs with `KERF_EVAL_HASHES` set once the real list exists and treats a skip as a gate
failure from then on (§9).

### 2.6 Adapter seam

The harness calls `Kerf.Decide.ask(state, questions, [adapter: adapter] ++ adapter_opts ++ extras)`
and nothing else; no `ask` injection, no direct `adapter.ask/3`. `state` is
`%Kerf.Decide.State{content: "From: …\nSubject: …\nDate: …\n\n<body>", provenance: %{taint: :tainted, origin: :ingress, sources: [item.id]}}`
(SPEC_G §4 shape; swap for `Kerf.Provenance.ingress(:email)` when it lands — Status S-4).
`extras`: `harness_gold: %{question_name => gold}` only when the adapter is `Kerf.Eval.Adapters.Oracle`;
`harness_seed: {seed, item_index * 64 + question_index, order_index}` (the 3-tuple `:rand.seed/2`
accepts, A3.11) only for `Kerf.Eval.Adapters.Random`.
Real adapters receive neither.

Adapters (`lib/kerf/eval/adapters/`): `Random` — uniform random probability vectors (normalized
uniforms) per Choice/Score, uniform `p_yes`, deterministic from `harness_seed`, `info/0`
`model_id: "eval-random"`. `Oracle` — `p = 0.97` on the gold label (rest spread evenly), `p_yes`
0.97/0.03 by gold, Score `expected` = gold level index, `confidence 0.97`, `model_id: "eval-oracle"`.
Both honour `Kerf.Decide.Adapter`.

### 2.7 CLI (`mix kerf.eval.decide`, owner: kerf-eval-harness)

```
mix kerf.eval.decide run      --manifest M --out run.jsonl --adapter http|random|oracle|Elixir.Mod \
                              --seed N [--base-url URL] [--allow-remote] [--timeout MS] \
                              [--permutations 6] [--isolation-items 30] [--limit N] [--skip-latency]
mix kerf.eval.decide score    --manifest M --run run.jsonl --report report.json --summary report.md \
                              [--baseline-accuracy F] [--host-class decoder|encoder] [--temperature-out temperatures.json]
mix kerf.eval.decide normalize --run run.jsonl --out run.norm.jsonl
mix kerf.eval.decide selftest --out-dir DIR [--manifest M|synthetic] [--seed N]      # F09.9
```
`run` refuses unless `Manifest.ready_for_run?/1` is `:ok` (F08.4). `--limit` is recorded in the
header and marks every gate `"pending"` (a partial run never passes). Random/oracle imply
`latency_skipped: true`. Mix task core logic lives in `Kerf.Eval.Harness.*`; the task file only parses
argv and wires I/O (SPEC_D §2 pattern, `Kerf.Eval.Replay` precedent).

### 2.8 Labelling UI mounting rule

`Kerf.Dashboard.Live.Eval.LabelPage` (LiveDashboard `PageBuilder`, like every existing page) is
appended to `additional_pages` in `lib/kerf/dashboard/router.ex` only when
`Application.compile_env(:kerf, :eval_ui)` is non-nil. `config/dev.exs` sets
`config :kerf, :eval_ui, manifest_path: System.get_env("KERF_EVAL_MANIFEST")`; `config/test.exs` sets
`config :kerf, :eval_ui, manifest_path: nil` (tests inject a tmp path with `Application.put_env`);
`config/prod.exs` and `config/runtime.exs` never mention `:eval_ui`, so the Spark release has no such
page (a test greps both files). The page reads `manifest_path` at runtime, calls only
`Manifest.load/put_label/put_tier/put_language/add_synthetic_item/mark_pair/save` and renders
`validate/1` violations; it never computes counts, tiers, splits or language itself. Freeze is not a
UI action (`mix kerf.eval.freeze`, owner-run).

---

## 3. Global constraints

- Public API of `Kerf.Decide*` is untouched by both groups (step 1 is closed).
- No file under `test/` changes in a GREEN commit; fixtures count as test files.
- `mix compile --warnings-as-errors`: only the 3 Postgrex `Kerf.PostgrexTypes` warnings tolerated in
  `lib/`, the runtime-compiled test Router warning in `test/`. `mix dialyzer`: 0 new warnings over the
  baseline of 4 (owner 2026-10-21 11:18, S-32 closed: PLT includes `:mix` and `:ex_unit`; the 4 are
  pattern_match_cov catch-alls in `system_page.ex:90`, `ollama_provider.ex:163`, `provider.ex:175`,
  `vllm_provider.ex:330`), mix task files included.
- Every public function has `@spec`; GenServers/pages never raise on I/O errors.
- No PII, client names or real addresses in any committed file; tests use `Manifest.Synthetic` only.
- Timestamps in manifests/runs are ISO8601 UTC strings; psql intervals use
  `(now() at time zone 'UTC') - interval '…'`.
- No `kb_feedback` writes, no Oban jobs, no Router calls from any eval code.
- Harness run files, reports, summaries and `temperatures.json` live only under
  `~/Projects/kerf/private/eval/decide/` (Mac) or `~/eval/decide/` (Spark). `mix kerf.eval.decide`
  (`run`, `score`, `normalize`, `selftest`) and `mix kerf.eval.export` refuse any `--out`,
  `--report`, `--summary`, `--temperature-out` or `--out-dir` path that resolves inside the repo
  root (`File.cwd!()` at task start, after `Path.expand/1`); tests use `System.tmp_dir!()`.
- Commits reference `SPEC_H_kerf_decide.json` and the check ids they close; single concern each.

## 4. Review focus (inputs the spec implies but no check names)

1. **JSON round-trip types** — `"3"`/`"true"` in labels must be rejected (`:label_wrong_type`), not
   coerced silently → D1 test.
2. **NULL body mails** (37 % of `kb_documents`) — export excludes `raw_text IS NULL`; manifest rejects
   `:empty_body` → D2/D1 tests (decision recorded, S-8).
3. **Same mail twice** — `:duplicate_doc_id` → D1 test.
4. **Pair split across splits** — freeze keeps both pair items in `eval` → D1 test.
5. **One adapter error mid-run** — error line, run continues, F09.6 fails, nothing raises → H3 test.

---

## 5. Executor ownership map (files never overlap)

| Executor | Owns (create/modify) | Tests |
|---|---|---|
| **kerf-eval-data** (F08) | `lib/kerf/eval/manifest.ex`, `lib/kerf/eval/manifest/**`, `lib/kerf/eval/export.ex`, `lib/mix/tasks/kerf.eval.export.ex`, `lib/mix/tasks/kerf.eval.freeze.ex`, `lib/kerf/dashboard/live/eval/**`, `lib/kerf/dashboard/router.ex` (one guarded block), `config/dev.exs`, `config/test.exs` (the `:eval_ui` entry only) | `test/eval/manifest_test.exs`, `test/eval/manifest/**`, `test/eval/export_test.exs`, `test/eval/pii_guard_test.exs`, `test/dashboard/eval/**` |
| **kerf-eval-harness** (F09) | `lib/kerf/eval/harness.ex`, `lib/kerf/eval/harness/**`, `lib/kerf/eval/adapters/{random,oracle}.ex`, `lib/mix/tasks/kerf.eval.decide.ex` | `test/eval/harness_test.exs`, `test/eval/harness/**`, `test/eval/adapters/**` |
| **lead** (this session) | `docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md`, gate runs, status relay | — |
| **owner** | `docs/superpowers/specs/SPEC_H_addendum_03.json`, everything in §8 | — |

Shared but read-only for both executors: `lib/kerf/decide*`, `lib/kerf/eval/replay.ex`,
`test/support/**`. Test layout is the house layout `test/eval/` (not `test/kerf/eval/`); the owner
updates the private notes, executors follow this plan.

Worktrees are sibling directories of the repo, one branch per executor; one task = one RED + one
GREEN commit on that branch. Created by the owner (or the lead on the owner's go) from `main`:

```bash
cd ~/Projects/kerf/kerf
git worktree add ../kerf-eval-data    -b eval/data    main
git worktree add ../kerf-eval-harness -b eval/harness main
```

Executor start commands (the public `CLAUDE.md` is tracked, so it is present in every worktree, and
its import `@/Users/wido/Projects/kerf/private/CLAUDE.md` is absolute, so the private notes load
there too; `<settings>` is the owner's per-executor settings file, if any):

```bash
cd ~/Projects/kerf/kerf-eval-data    && claude --name kerf-eval-data    --model sonnet --settings <settings>
cd ~/Projects/kerf/kerf-eval-harness && claude --name kerf-eval-harness --model sonnet --settings <settings>
```

Opus tasks (D1, H2) are started with `--model opus` for that task's session, or the lead asks the
owner to switch the model before messaging the task.

Dependency: **H3 and H4 need D1 merged** (struct + `Synthetic`). H1 and H2 need nothing from D.
Order of starts: D1 and H1 immediately; H2 right after H1; H1b after H2 (S-22); D2/D3/D4 after D1;
H3 after D1 lands on `main` and after H1b; H4 after H3 (S-2 is decided: see §10.2).

---

## 6. Tasks — kerf-eval-data

### D1 — Manifest struct, loader, validator, freeze, synthetic set  (model: **Opus** — the validator is the single point every other part trusts; a wrong invariant here silently corrupts the evidence)

**Closes:** F08.1 (counts/mix check), F08.2 (label validation), F08.3, F08.4 (`ready_for_run?`), F08.5, F08.7 (label_sources).
**Files:** create `lib/kerf/eval/manifest.ex`, `manifest/item.ex`, `manifest/synthetic.ex`, `manifest/language.ex`, `manifest/overrides.ex`, `manifest/question_set.ex`.
**RED tests:** `test/eval/manifest_test.exs` (load/validate/save round-trip; every violation code in §2.1 with one failing manifest each; `:duplicate_doc_id` fires for two real items with the same `doc_id` and does **not** fire for two synthetic items with `doc_id: nil`; `put_label` rejects wrong types and unknown options, sets `labelled_at`, keeps `"adjudicated"`; `put_tier` requires reason; `labelled_by == "wido"` (S-19); `freeze` refuses on <200 / <20 pairs / unlabelled / mix shortfall unless allowed, assigns exactly 50 calibration, never a pair item, same seed → same split; `assign_split/3` quotas over the eligible pool with each (language, tier) stratum ∈ {⌊quota⌋, ⌈quota⌉} and a total of exactly n (S-18); `validate` rejects a `question_set` whose keys are not exactly `QuestionSet.order/0` (`:question_set_keys`); `training_export` excludes calibration; `items(:calibration)` returns 50; `ready_for_run?` fails when a `tiered_at` > `frozen_at` or unfrozen; `sha256/1`), `test/eval/manifest/synthetic_test.exs` (seeded, validates, 220/24 defaults, no address outside `example.invalid`, same seed → identical JSON; `build()` has 244 items of which 220 real and 24 synthetic (`counts.pairs == 24`); `build(frozen: false)` then `freeze/4` succeeds and equals `build()`'s split (50 calibration); `build(n: 8, pairs: 2)` has 10 items, is frozen, validates, `ready_for_run?` `:ok`, exactly 1 calibration item, no pair item in calibration — S-17), `test/eval/manifest/language_test.exs` (NL/DE/EN sample sentences, `"und"` for empty), `test/eval/manifest/overrides_test.exs` (SPEC_D line shape, bad `label_true`, malformed line → error), `test/eval/manifest/question_set_test.exs` (`order/0` is literally `["category", "needs_reply", "urgency", "deadline_present", "client"]`; `phase_b/1` has exactly those keys; category options == `Kerf.Decide.OptionSet.triage_categories() |> labels`, `"none"` last in client).
**GREEN gate:** `mix test test/eval/manifest_test.exs test/eval/manifest/ --no-start --seed 1` and `--seed 99999` green; full suite both seeds; compile/dialyzer clean.

### D1b — Question-definition shape check, never a raise  (model: Opus kept — lead recommendation, see S-26; owner go 21:11, option (a))

**Closes:** F08.1/F08.2 "nothing raises" for `load/1` and `validate/1` on a malformed `question_set` (S-26).
**Files:** modify `lib/kerf/eval/manifest.ex` only. Tests: `test/eval/manifest_test.exs` only.
**RED tests:** two `load/1` tests on a tmp `manifest.json` written from `Synthetic.build()` with the `question_set` hand-edited: (1) `"category"` `"options"` set to a non-list, (2) `"urgency"` `"levels"` set to a non-list. Each asserts `{:error, [{:question_def_invalid, nil, {"category", _}} | _]}` (resp. `{"urgency", _}`) — the code heads the list — and that no `{:unknown_question_type, _, _}` is in the list. In RED these fail in-body (today the call raises). Commit `test(RED): SPEC_H D1b — question_set definition shape is a violation, never a raise (F08.1, F08.2)`.
**GREEN:** one manifest-level question-definition shape check run once before the per-item checks, emitting `{:question_def_invalid, nil, {question_key, reason}}`; `is_list` guards so `check_label/4` cannot raise; per-item question-type checks are skipped for a manifest whose definitions are invalid. Commit `feat: Manifest.validate/1 — manifest-level question definition check (SPEC_H F08.1, F08.2, S-26)`.
**GREEN gate:** `mix test test/eval/manifest_test.exs test/eval/manifest/ --no-start` both seeds; full suite both seeds; dialyzer 0 new. Branch starts on top of ff0b859; if `main` has moved (owner merge), rebase first.

### D2 — Export (`Kerf.Eval.Export`, `mix kerf.eval.export`) and `mix kerf.eval.freeze`  (model: Sonnet)

**Closes:** F08.1 (export with real From/Subject/Date via `source_metadata`), F08.7 (seeding from overrides, `"adjudicated"`).
**Read-back first (executor, read-only ssh):** `SELECT current_database();` (or `\l`) to verify the database name — it becomes the default of `--db`; `\d kb_documents`; confirm `doc_id` in `~/eval/golden-overrides.jsonl` matches `kb_documents.id` (or `source_id`) with one `SELECT … WHERE id = ANY(…)`. If it matches neither, stop and write Status S-3. Fourth item (owner, 2026-10-20 22:51): the `raw_text IS NULL` share per `source_type` (`count(*) FILTER (WHERE raw_text IS NULL)` vs `count(*)`, grouped), to confirm the ~37 % figure behind S-8. All four results go to the lead **before** any RED test is written (the owner rules on them); the RED commit message quotes (a)–(c) structurally — never an address, subject, sender or body.
**Files:** create `lib/kerf/eval/export.ex`, `lib/mix/tasks/kerf.eval.export.ex`, `lib/mix/tasks/kerf.eval.freeze.ex`; modify `lib/kerf/eval/manifest/item.ex` (field `source_id`, default nil) and `lib/kerf/eval/manifest.ex` / `manifest/synthetic.ex` only as far as the loader, encoder and `Synthetic` need to carry it (owner addition 2026-10-21). **`--db` default is `"kerf_prod"`** (owner ruling 2026-10-21 on the read-back, S-27): the literal appears exactly once in `lib/kerf/eval/export.ex`, as the parse_args default, and the RED asserts both that default and that `--db other_db` overrides it.
**Interfaces produced:**
```elixir
Export.query(opts)        :: String.t()
# SELECT id AS doc_id, source_id, source_metadata->>'sender' AS from, ->>'sender_name' AS from_name,
#        ->>'subject' AS subject, ->>'date' AS date, raw_text AS body, inserted_at
# FROM kb_documents
# WHERE source_type = 'email'
#   AND raw_text IS NOT NULL
#   AND (inserted_at >= (now() at time zone 'UTC') - interval '<since>' OR id = ANY('{…}'))
# ORDER BY inserted_at DESC, id LIMIT n   — emitted as `SELECT row_to_json(t) FROM (…) t`
# The OR is parenthesised INSIDE the AND chain: override ids must still pass the source_type and
# raw_text filters (unparenthesised, `A AND B AND C OR D` parses as `(A AND B AND C) OR D`).
Export.ssh_command(host, db, sql) :: [String.t()]   # ["ssh", host, "export PATH=\"$HOME/.asdf/shims:$PATH\"; psql -d <db> -At <<'SQL'\n…\nSQL"]; db comes from --db, whose default is the name verified in the read-back — never a literal elsewhere
Export.fetch_rows(opts)   :: {:ok, [map]} | {:error, term}   # opts[:runner] :: ([String.t()] -> {String.t(), integer}), default System.cmd
Export.parse_rows(jsonl)  :: {:ok, [map]} | {:error, term}
Export.select(rows, overrides, opts) :: [map]   # all override doc_ids first, then fill to opts[:target] (220) by Language.guess toward NL≥40/DE≥25/EN≥20, deterministic
Export.build_manifest(rows, overrides, opts) :: Manifest.t()   # ids it-0001…, language_source "heuristic", category seeded "adjudicated"
```
CLI: `mix kerf.eval.export --out PATH --overrides PATH --clients PATH [--since 180d] [--limit 600] [--target 220] [--host spark] [--db NAME] [--raw raw.jsonl] [--hashes-out PATH]`; `mix kerf.eval.freeze --manifest PATH --seed N [--allow-mix-shortfall]`. `--out` and `--hashes-out` inside the repo root are refused (§3).
**RED tests:** `test/eval/export_test.exs` — query contains `source_type = 'email'`, `raw_text IS NOT NULL`, the naive-UTC interval, `ORDER BY inserted_at DESC, id`, no `now()` without `at time zone`; the `OR id = ANY` clause sits inside parentheses that are themselves preceded by `AND` (assert with a regex like `~r/AND \(inserted_at >= .*? OR id = ANY\(.*?\)\)/s` and assert no `OR` appears outside parentheses); `ssh_command(host, db, sql)` has the asdf prefix and heredoc and uses exactly the `db` argument (`"-d other_db"` when passed `"other_db"` — no literal database name asserted); `parse_args` honours `--db` and defaults it to the read-back value; `fetch_rows` with an injected runner (non-zero exit → error); `parse_rows` tolerates a bad line; `select` includes all override ids and is deterministic; `build_manifest` validates, seeds category only where an override exists and marks it `"adjudicated"`, leaves other labels nil; freeze task argv parsing (`Kerf.Eval.Export.parse_args/1` style, never raises). `source_id` (RED, owner addition): rows from `parse_rows/1` carry `source_id`; `build_manifest/3` copies it onto each item; a manifest with `source_id` set survives `save/2` → `load/1`; `Synthetic.build/1` gives real items `"src-<n>"` and pair items nil — asserted with `assert %{source_id: _} = item` pattern matches (never a `%Item{source_id: …}` literal, so the RED compiles and fails as an assertion); these struct-level tests may live in `test/eval/manifest_test.exs` / `manifest/synthetic_test.exs`, which are in the same owner block.
**GREEN gate:** `mix test test/eval/export_test.exs --no-start` both seeds; full suite both seeds.

### D3 — PII guard  (model: Sonnet)

**Closes:** F08.6.
**Files:** create `lib/kerf/eval/manifest/pii.ex` (`address_hashes(manifest) :: [hex]`, `write_hashes(hashes, path)`, `read_hashes(path) :: {:ok, [hex]} | {:error, term}`, `scan(paths, hashes) :: [{file, line_no}]`). No file under the repo (A3.7).
**RED tests:** `test/eval/pii_guard_test.exs` (`@moduletag :pii_guard`) — the list at `KERF_EVAL_HASHES` parses via `read_hashes/1`; when the variable is unset the module prints a notice naming `KERF_EVAL_HASHES` and skips (asserted with a tmp env in a helper test: `System.delete_env` → notice captured with `ExUnit.CaptureIO`, no assertion runs); with it set, scanning the four directories finds no hashed address; unit test of `scan/2` with a tmp file containing a synthetic address whose hash is in a tmp list → reported; `write_hashes/2` then `read_hashes/1` round-trips and sorts.
**GREEN gate:** `mix test test/eval/pii_guard_test.exs --no-start` both seeds.

### D4 — Labelling page  (model: Sonnet)

**Closes:** F08.2 (labelling path writes through the loader), F08.3 (pair marking), F08.4 (tier + reason + `tiered_at` captured), F08.1 (language override).
**Files:** create `lib/kerf/dashboard/live/eval/label_page.ex` (`Kerf.Dashboard.Live.Eval.LabelPage`, `use Phoenix.LiveDashboard.PageBuilder`, `menu_link/2` → `"Eval Labels"`); modify `lib/kerf/dashboard/router.ex` (append `eval_label: Kerf.Dashboard.Live.Eval.LabelPage` to `additional_pages` under `if Application.compile_env(:kerf, :eval_ui)`), `config/dev.exs`, `config/test.exs` (§2.8).
**Behaviour:** `mount` loads the manifest from `Application.get_env(:kerf, :eval_ui)[:manifest_path]` (missing/invalid → page renders the violations, no crash); list with filters (unlabelled, language, tier); item view shows `state` fields; one form posting `labels` (5 fields), `tier`, `tier_reason`, `language`; events `"save_label"`, `"save_tier"`, `"save_language"`, `"add_synthetic"`, `"mark_pair"` each call the matching `Manifest.put_*` then `Manifest.save/2`, and render violations verbatim; progress line from `manifest.counts`.
**RED tests:** `test/dashboard/eval/label_page_test.exs` (`use Kerf.ConnCase`, `@moduletag :integration`; tmp copy of `Manifest.Synthetic.build(n: 12, pairs: 2)` (14 items) with labels removed; `live(conn, "/dashboard/eval_label")` renders items; saving a valid label updates the file and `labelled_at`; an invalid label shows the violation and leaves the file unchanged; tier without reason refused; `mark_pair` on items with identical labels refused), `test/dashboard/eval/eval_ui_config_test.exs` (`config/prod.exs` and `config/runtime.exs` contain no `:eval_ui`; `router.ex` contains `compile_env(:kerf, :eval_ui)`).
**Dispatch 2026-10-22 09:50 (lead; live-code read-back at main 92b6e07, binding for the RED):** `eval/data` fast-forwards onto 92b6e07 first. Live state: `router.ex:22-31` is one `live_dashboard "/dashboard"` call whose `additional_pages` is a literal keyword list of six `kerf_*` pages; no file under `config/`, `lib/` or `test/` mentions `:eval_ui` today; `Kerf.ConnCase` (`test/support/conn_case.ex`) sets `@endpoint Kerf.Dashboard.Endpoint` and imports `Phoenix.LiveViewTest`; `test/dashboard/dashboard_live_test.exs` uses `use Kerf.ConnCase, async: false` + `@moduletag :integration` (excluded under `--no-start`, run in every full suite because the app is started); existing pages (`system_page.ex:3-6`) use `use Phoenix.LiveDashboard.PageBuilder` and `menu_link(_, _) -> {:ok, "…"}`. The page key `eval_label` mounts at `/dashboard/eval_label`. `Application.compile_env(:kerf, :eval_ui)` is non-nil in test because `config/test.exs` sets `manifest_path: nil` (the test then `Application.put_env`s a tmp path and restores it in `on_exit`); the manifest path is read at mount, never at compile time. Form fields arrive as strings; the page converts the five label fields to the loader's types (boolean, integer 1..5) before `put_label/4` — the loader rejects `"3"`/`"true"` (§4 item 1) — and one RED asserts that urgency `"3"` from the form lands as integer `3` in the saved file. No state field value appears in a test literal except `Synthetic`'s `example.invalid` data. **The same RED commit carries two more pins, both inside the data owner block:**
- **S-29 follow-up** (`test/eval/manifest_test.exs`; lib `manifest.ex:457-458`): today `put_label/4` keeps `"adjudicated"` whenever `label_sources["category"]` already is. New rule: `label_sources["category"]` is `"adjudicated"` iff `item.seed_category` is non-nil **and** `labels["category"] == item.seed_category`; otherwise `"new"`. Three tests: seeded + equal → `"adjudicated"` (green today), seeded + differing → `"new"` (red today), nil seed → `"new"` (green today). `seed_category` itself is never changed by `put_label/4`.
- **S-35(d)** (`test/eval/pii_guard_test.exs`, round-trip describe; lib `pii.ex:54-66`): the file written by `PII.write_hashes/2` has mode `0o600` (`Bitwise.band(File.stat!(path).mode, 0o777) == 0o600`); GREEN sets the mode on the tmp file before the rename, the tmp + rename shape and the header unchanged. Reassigned here from H4b because `pii.ex` is in this owner block (S-35 note 1).
Commit `test(RED): SPEC_H D4 — labelling page, :eval_ui mounting, seed-aware label source, 0o600 hashes file (F08.1, F08.2, F08.3, F08.4, S-29, S-35)`; GREEN `feat: Kerf.Dashboard.Live.Eval.LabelPage — labelling through the loader; put_label seed-aware source; 0o600 hashes file (SPEC_H F08.1–F08.4, S-29, S-35)`.
**GREEN gate:** `mix test test/dashboard/eval/` (app started) both seeds; full suite both seeds.

---

## 7. Tasks — kerf-eval-harness

### H1 — Run format, question building, Random and Oracle adapters  (model: Sonnet)

**Closes:** F09.6 (in-schema enforced at the seam — the test proves both adapters pass `Kerf.Decide.ask/3` validation), F09.8 (normalize), F09.9 (the two adapters).
**Files:** create `lib/kerf/eval/harness/run.ex` (`header/1`, `answer_line/1`, `end_line/1`, `write/3`, `read/1 :: {:ok, {header, lines, end}} | {:error, term}`, `normalize/1`), `lib/kerf/eval/harness/questions.ex` (`order/0` — the fixed Phase B key list, equal to `Kerf.Eval.Manifest.QuestionSet.order/0`; `from_question_set(question_set) :: {:ok, [Kerf.Decide.Question.t()]} | {:error, term}` in `order/0` order (tagged tuple so the unknown-key error has a shape — pinned in H1 RED 44aa772), names atomized from the fixed Phase B key list only — unknown keys are an error, never `String.to_atom/1`; `permute(questions, orders)`; `orders_for(question, seed, item_index, question_index, n)` (seeds `:rand` with the 3-tuple of §2.3 per order index); `secret_probe(token)`), `lib/kerf/eval/adapters/random.ex`, `lib/kerf/eval/adapters/oracle.ex`.
**RED tests:** `test/eval/harness/run_test.exs` (JSONL round-trip, deterministic encoding, `normalize` drops exactly the four keys, malformed file → error), `test/eval/harness/questions_test.exs` (hand-built `question_set` map → 5 questions, category OptionSet in manifest order, `orders_for` seeded and identity at index 0, unknown key → error), `test/eval/adapters/random_test.exs` and `oracle_test.exs` (each through `Kerf.Decide.ask/3`: results in-schema for all three types; Random identical for identical `harness_seed`, different otherwise; Oracle picks `harness_gold` under any option order, `p_yes` ≥ 0.9 iff gold true).
**GREEN gate:** `mix test test/eval/harness/ test/eval/adapters/ --no-start` both seeds; full suite both seeds.

### H2 — Scoring and report  (model: **Opus** — ECE binning, temperature fit and stratified accuracy are where a subtle error passes the oracle/random self-test yet misranks real models)

**Closes:** F09.1, F09.2, F09.3, F09.4, F09.5, F09.6, F09.7 (scoring side), F07.3 histogram shape.
**Files:** create `lib/kerf/eval/harness/score.ex`, `lib/kerf/eval/harness/report.ex`.
**Interfaces:** `Score.score(header, lines, manifest_items, opts) :: report_map` with `opts[:baseline_accuracy]`, `opts[:host_class]`; pure sub-functions `accuracy/2`, `ece/1`, `fit_temperature/1`, `apply_temperature/2`, `flip_rate/1`, `isolation/1`, `latency/1`, `coverage/2`, `contrastive/2`, `histograms/1`, `gates/1`; `Report.to_json(report) :: iodata` (sorted keys), `Report.to_markdown(report) :: String.t()` (deterministic; the only timestamp is `run.started_at`).
**RED tests:** `test/eval/harness/score_test.exs` with hand-built lines: ECE of a perfectly calibrated 2-bin set is 0 and of a 0.9-confident/0.5-accurate set is 0.4; `bin` edge rule (`p = 1.0` → bin 9, `0.1` → bin 1); temperature fit returns `T < 1` for under-confident correct probs and `T > 1` for over-confident, applied probs still sum to 1 ± 1e-9; flip rate counts only `order_index 1..5` vs 0 and splits by tier; contrastive pass/fail per §2.4 rule; coverage counts errors and missing lines; isolation means and agreement; latency percentiles (nearest-rank) and `null` when `latency_skipped`; gates `pending` when baseline nil or `limit` set; histograms 10 bins per question with `model_id` from header; `to_json` byte-identical for maps built in different key orders.
**GREEN gate:** `mix test test/eval/harness/score_test.exs --no-start` both seeds; full suite both seeds.

### H1b — Permutations by functional Fisher–Yates, no `Enum.shuffle`, no Task  (model: Sonnet) — **after H2, before H3** (owner pre-push review of df95c9d, S-22)

**Closes:** F09.8 (order permutations depend only on the `:exsss` algorithm and the seed tuple, not on `Enum.shuffle` internals or on a spawned process).
**Files:** modify `lib/kerf/eval/harness/questions.ex` only (`orders_for/5`; public signature unchanged).
**Behaviour:** `orders_for(question, seed, item_index, question_index, n)` returns `n` orders of the question's labels (manifest order). `order_index 0` is the identity. For each `order_index` in `1..n-1`: `state0 = :rand.seed_s(:exsss, {seed, item_index * 64 + question_index, order_index})`; then a Fisher–Yates over the identity list `a` of length `k` — for `i` from `k - 1` down to `1`: `{j, state} = :rand.uniform_s(i + 1, state)` (`j ∈ 1..i+1`), swap `a[i]` and `a[j - 1]` — with the state threaded through every step. No `Task`, no `Enum.shuffle`, no `:rand.seed/2`: the caller's process-dictionary `:rand` state is never read or written.
**RED tests:** `test/eval/harness/questions_test.exs`: (1) `expected_order/5` becomes an independent re-statement of exactly the Fisher–Yates above with the same seeding, written in the test and never calling `lib/`; the existing seeded-permutation assertions keep using it (they go red against the current `Enum.shuffle` implementation). (2) `orders_for/5` leaves the caller's `:rand` state untouched: `:rand.seed(:exsss, {1, 2, 3})`, `before = :rand.export_seed()`, call `orders_for/5`, `assert :rand.export_seed() == before` (the D1 `assign_split/3` purity pattern). (3) Golden: `orders_for(category_question, 7, 3, 2, 6)` equals a literal list of 6 orders written into the test; the literal is produced once by the test's own `expected_order/5` during the RED run and pasted in, so a future drift of either the algorithm or the seeding fails loudly. The RED commit message quotes the three test names.
**GREEN:** implementation only, no edits under `test/`; commit `refactor: Questions.orders_for/5 functional Fisher–Yates over :rand.uniform_s (SPEC_H F09.8, S-22)`.
**GREEN gate:** `mix test test/eval/harness/questions_test.exs test/eval/harness/ test/eval/adapters/ --no-start` both seeds; full suite both seeds; dialyzer 0 new.

### H3 — Harness orchestration over a manifest  (model: Sonnet) — **starts after D1 is on `main` and after H1b**

**Closes:** F09.3/F09.4/F09.6 (request generation), F09.8 (deterministic order), F08.4 (refuses an unready manifest).
**Files:** create `lib/kerf/eval/harness.ex` — `run(manifest, opts) :: {:ok, %{header, lines, end}} | {:error, term}` with `opts`: `adapter`, `adapter_opts`, `manifest_path` (the file the manifest was loaded from; hashed for the header, S-23b), `seed`, `permutations` (6), `isolation_items` (30: the first 30 eval items by id), `limit`, `skip_latency`, `sink` (fn line -> :ok, default no-op; the mix task streams to disk). Builds the state string and provenance per §2.6; asks main requests per order, separate requests, isolation probes with token `"KERF-" <> (Base.encode16(:crypto.hash(:sha256, Integer.to_string(seed)), case: :lower) |> binary_part(0, 12))` — parenthesised so the 12 hex chars follow the prefix (A3.12; the H3 RED asserts `token =~ ~r/\AKERF-[0-9a-f]{12}\z/`); never calls an adapter directly (test greps `lib/kerf/eval/harness.ex` for `.ask(` other than `Kerf.Decide.ask`). The H3 RED also asserts `Kerf.Eval.Harness.Questions.order() == Kerf.Eval.Manifest.QuestionSet.order()` (S-16).
**RED tests:** `test/eval/harness_test.exs` using `Kerf.Eval.Manifest.Synthetic.build(n: 8, pairs: 2)` (10 items, 1 calibration): line count = 10 × (6×5 + 5) + 2 × min(isolation_items, eval items) isolation lines (with `isolation_items: 30` and 9 eval items: 350 + 18 = 368 answer lines); order of lines as §2.3; `order_index 0` is identity; same seed → identical normalized output across two runs (F09.8); unfrozen or late-tiered manifest → `{:error, …}` (F08.4); a crashing stub adapter on one item yields an error line and the run completes; `harness_gold` present only for Oracle, `harness_seed` only for Random (stub adapter records opts); `limit` recorded in header. **Owner pins (2026-10-20):** `harness_gold` is atom-keyed (`%{category: …, needs_reply: …, urgency: 1..5, deadline_present: …, client: …}` plus `secret_present:` for probes), converted from the manifest's string keys through the fixed Phase B list (`Questions.order/0`), never `String.to_atom/1`; `harness_seed` is the ready 3-tuple `{seed, item_index * 64 + question_index, order_index}` computed by the harness, passed through to Random as-is (the RED asserts both shapes on the recorded opts). **Owner pins (2026-10-20, pre-push review of df95c9d):** the run header's `adapter` field is the module's `inspect/1` string (`"Kerf.Eval.Adapters.Random"`), never `Atom.to_string/1` (which yields `"Elixir.…"`); the harness hands `Run.header/1`, `Run.answer_line/1` and `Run.end_line/1` plain maps, never structs — `Run.jsonable/1` does not handle structs. The H3 RED asserts the header's `adapter` string for a stub adapter and that the harness passes maps (a struct in the header input is an error, not a silent encode). **Owner pin (2026-10-20, S-23b):** the header's `manifest_sha256` is the `hex` from `Manifest.sha256(opts[:manifest_path])` taken through a `case`/`with` (never a bare `{:ok, hex} =` match): `{:ok, hex}` fills the header, `{:error, reason}` aborts the run as `{:error, {:manifest_sha256, reason}}` before any request is made; `opts[:manifest_path]` is the path the mix task loaded the manifest from and also fills the header's `manifest_path` (the H3 RED asserts the abort with an unreadable path and a stub adapter that records zero calls).
**GREEN gate:** `mix test test/eval/harness_test.exs --no-start` both seeds; full suite both seeds.

### H4 — Mix task and self-test  (model: Sonnet) — **starts after H3** (S-2 decided, see §10.2)

**Closes:** F09.9, F09.8 (CLI `normalize`), F09.5 (recording; real hosts are F10).
**Files:** create `lib/mix/tasks/kerf.eval.decide.ex`, `lib/kerf/eval/harness/cli.ex` (`parse_args/1` → `{:ok, %{command, …}} | {:error, msg}`, never raises; adapter alias table `http → Kerf.Decide.Adapter.HTTP`, `random`, `oracle`, `Elixir.*` → `Module.safe_concat`), `lib/kerf/eval/harness/selftest.ex` (`run(out_dir, opts) :: {:ok, summary} | {:error, failures}`: synthetic manifest unless `--manifest`; random run+score, oracle run+score twice; asserts random `fail` on F09.1, F09.7 and on **raw** ECE > 0.08 for every noul/choice question, while random's scaled F09.2 result is reported in the summary and not asserted (S-2 decision); oracle `pass` on every gate except F09.5 `skipped`; two oracle runs normalized-identical and reports identical; writes all artefacts under `out_dir`).
**RED tests:** `test/eval/harness/cli_test.exs` (every subcommand's required flags, bad adapter alias → error, `--limit` parsed; the `run` help text states `--limit`'s scope semantics — the first N items in manifest order, isolation items chosen from the eval items in that scope (owner pin 2026-10-21 at H3 GREEN; the RED asserts the two phrases in the help output); every output path flag that resolves inside `File.cwd!()` → `{:error, msg}` naming the flag, a `System.tmp_dir!()` path accepted — §3 repo-root refusal; `Harness.run/2` with `manifest_path: nil`, no `:adapter` or no `:seed` returns `{:error, _}` and never raises (harness.ex:37/:84 `Keyword.fetch!` today, lead addition at dispatch); the run file name derives from `--out`, never from `run_id` (it contains colons) — H3 GREEN notes 2026-10-21; `--base-url` outside loopback refused without `--allow-remote`, `--base-url`/`--timeout` rejected for `random`/`oracle` — lead reading S-34, owner may veto), `test/eval/harness/selftest_test.exs` (runs `Selftest.run/2` into a tmp dir on `Synthetic.build(n: 60, pairs: 6)` (66 items, 11 calibration); asserts the summary; asserts artefact files exist and the oracle report sha256s match) — this is the F09.9 self-test itself, run in CI.
**GREEN gate:** `mix test test/eval/harness/cli_test.exs test/eval/harness/selftest_test.exs --no-start` both seeds; full suite both seeds; then owner runs `mix kerf.eval.decide selftest --out-dir ~/Projects/kerf/private/eval/decide/selftest/` once and files the summary (step-3 entry gate: "F09.9 self-test passes before any real model is run").


### H4b — Run hardening: `--out` refusal, sink write errors, `:req` start failure  (model: Sonnet) — **after H4 merged (92b6e07), before any F10 run** (owner 2026-10-22, S-35)

**Closes:** F09.8 (a run file is never two runs interleaved or overwritten by accident; a truncated run never carries `run_end`), F09.6 (a write error surfaces as `{:error, …}`, never as a silently short file).
**Files:** modify `lib/kerf/eval/harness/cli.ex`, `lib/kerf/eval/harness.ex`, `lib/mix/tasks/kerf.eval.decide.ex` only. Tests: `test/eval/harness/cli_test.exs`, `test/eval/harness_test.exs`, new `test/eval/harness/decide_task_test.exs`.
**Live state (lead read-back at 92b6e07):** `cli.ex:412` sink is `fn line -> IO.binwrite(file, Run.encode(line) <> "\n") end`, return dropped; `harness.ex:47`, `:52`, `:63` call `sink.(…)` and drop the return; the default sink (`harness.ex:37`) and the H3 sink test (`harness_test.exs:725-728`) return `:ok`; `kerf.eval.decide.ex:28` is `{:ok, _apps} = Application.ensure_all_started(:req)` — a `MatchError` today; the export rule is `export.ex:351` `if File.exists?(path), do: {:error, "#{path} exists; refusing to overwrite it"}` (export has no `--force`; the flag is new to this CLI).
**Behaviour (binding):**
- (a) `parse_args/1` accepts boolean `--force` for `run` only (an error for `score`/`normalize`/`selftest`). Without it, `CLI.run/1` on an existing `--out` returns `{:error, msg}` with `msg =~ ~r/exists; refusing to overwrite/` **before** the manifest is loaded or any adapter call is made, and the file's bytes are unchanged; with `--force` the file is replaced. `normalize --out` and `selftest --out-dir` are not changed by this task.
- (b) Sink contract: `sink :: (map() -> :ok | {:error, term()})`. `Harness.run/2` checks every return: `{:error, reason}` → `run/2` returns `{:error, reason}` at once, no further sink call, `run_end` neither built nor passed; `:ok` continues; the success tuple is unchanged. `CLI.file_sink(device, path)` becomes public and returns a sink that calls `:file.write/2` (not `IO.binwrite/2`, which raises on a write error — S-35 note 5) and maps its `{:error, reason}` to `{:error, {:write_failed, path, reason}}`; `CLI.run/1` returns that tuple verbatim. Tests: harness-level — a sink returning `{:error, {:write_failed, "/x", :enospc}}` on its third call gives `run/2 == {:error, {:write_failed, "/x", :enospc}}`, exactly three sink calls, none a `run_end`; CLI-level — `file_sink/2` over a device opened `[:read]` returns `{:error, {:write_failed, path, _}}`, over a writable device returns `:ok` and writes `Run.encode(line) <> "\n"`.
- (c) `Mix.Tasks.Kerf.Eval.Decide.run/2` (`run(argv, opts)`, `run/1` = `run(argv, [])`) takes `opts[:starter]` (default `&Application.ensure_all_started/1`); a starter returning `{:error, reason}` makes the task raise `Mix.Error` whose message contains `inspect(reason)`, and `CLI.run/1` is not reached (the test injects `fn :req -> {:error, {:req, {:boom, :finch}}} end` with a tmp `--out` that must stay absent). `Mix.raise/1` is the only raise; `app.config` still runs first.
- (d) 0o600 on the hashes file is **D4's** (data owner block; S-35 note 1).
- Symlink resolution in `inside?/2` (`cli.ex:143`, `export.ex:467`) stays on the later-RED list.
**RED commit:** `test(RED): SPEC_H H4b — run refuses an existing --out unless --force, sink write errors abort without run_end, :req start failure raises (F09.8, F09.6, S-35)`. **GREEN commit:** `fix: mix kerf.eval.decide run — --force, checked sink writes, :req start failure (SPEC_H F09.8, F09.6, S-35)`.
**GREEN gate:** `mix test test/eval/harness_test.exs test/eval/harness/ test/eval/adapters/ --no-start` both seeds; full suite both seeds; `cli_test.exs:489` ("written at exactly --out and nothing else") must stay green; dialyzer 0 new over 4; nothing under `test/`.

---

## 8. Owner handoff items (only the owner can do these)

- H-1 Label every item in the dev LiveDashboard page (`KERF_EVAL_MANIFEST=~/Projects/kerf/private/eval/decide/manifest.json PHX_SERVER=true mix run --no-halt`, then `http://localhost:4000/dashboard/eval_label`), ~2 h per language; tier each item with a reason; author ≥ 20 synthetic pair items; override language where the heuristic is wrong; write the one-page labelling guideline in `~/Projects/kerf/private/eval/decide/LABELLING.md` (F08.2).
- H-2 Provide `~/Projects/kerf/private/eval/decide/clients.txt` (one client id per line) before D2's first real export.
- H-3 Run `mix kerf.eval.freeze --manifest … --seed 1` (point of no return; `--allow-mix-shortfall` is your call, recorded in the manifest).
- H-4 Copy the frozen manifest to the Spark `~/eval/decide/manifest.json` (scp = state-changing on the Spark).
- H-5 Run `mix kerf.eval.export … --hashes-out ~/Projects/kerf/private/eval/decide/address_hashes.txt`; keep the file in the private tree; export `KERF_EVAL_HASHES=<that path>` in the shell the lead's gate runs use (A3.7). Nothing is committed.
- H-6 Commit `SPEC_H_addendum_03.json` from the Status entries marked "→ addendum 03".
- H-7 Authorize each GREEN; merge each gated branch to `main`; `git push`.
- H-8 Create the two worktrees and start the executor sessions (§5 commands).
- H-9 Run the self-test once on the M5 and file its summary in the private tree (step-3 entry gate). Owner sequencing 2026-10-21 11:48: after D3 and H4 merge, H-9 runs `mix kerf.eval.decide selftest --out-dir ~/Projects/kerf/private/eval/decide/selftest/`; then the lead dispatches D4 (labelling page, with the S-29 follow-up RED), the last data task before H-1/H-2/H-3. **Done 2026-10-22:** self-test passed on main 92b6e07, oracle report sha256 `d332ce14…7945`, summary filed in the private tree — step-3 entry gate met.

## 9. Gate procedure (lead enforces; applies to every task)

1. Executor, in its worktree on its branch: writes RED tests + raising skeletons only
   (`raise "not implemented (SPEC_H F0x.y)"`), runs the task's test files with `--seed 1` and
   `--seed 99999`, confirms each fails in-body for the right reason, commits
   `test(RED): SPEC_H <task> — <one line> (F0x.y, …)`, messages the lead "RED <task> <sha>" and idles.
2. Lead, in this checkout: `git checkout <sha>`; runs the task's own test files with `--seed 1` and
   `--seed 99999` and records each failure's kind — `RuntimeError: not implemented …` from a
   skeleton, or an `ExUnit.AssertionError` from a body assertion, are the only acceptable kinds;
   a compile error, `UndefinedFunctionError`, `FunctionClauseError` in setup, or a failure that
   differs between the two seeds is a defect and the RED goes back to the executor. Then
   `mix test --seed 1`, `mix test --seed 99999` (full suite: only the new tests fail),
   `mix compile --warnings-as-errors` (3 tolerated), owner-block check
   (`git diff --stat main..<sha>`), back to `main`, one message to the owner with the counts and kinds.
   Once the real address-hash list exists (H-5), every gate run is made with `KERF_EVAL_HASHES`
   set, and a printed `:pii_guard` skip in the output is a gate failure (A3.7).
3. Owner authorizes GREEN. Lead relays.
4. Executor implements, no edits under `test/`, commits
   `feat: <module> … (SPEC_H F0x.y)`; messages "GREEN <task> <sha>" and idles.
5. Lead: same two seeds on the GREEN sha, `git diff <red>..<green> --stat -- test/` must be empty,
   `mix dialyzer` 0 new, owner-block check; one message to the owner.
6. Owner merges (or authorizes the lead to `git merge --ff-only`), pushes.
7. Deviations found at any step go to §10 first; work on that task stops until the owner answers.

## 10. Status (executors append here; one entry per gate; newest last)

### 10.1 Gate log

| Date | Task | Event | Sha | Seeds 1 / 99999 | Notes |
|---|---|---|---|---|---|
| 2026-10-20 | — | plan written | — | — | owner review |
| 2026-10-20 | — | plan approved by owner 2026-10-20 (with changes 1–8: SQL precedence, `--db` read-back, nil `doc_id`, S-2 ruling, repo plan path, worktree commands, private-tree output constraint, RED failure-kind check) | 9aa38b0 | — | executors may start D1 and H1 |
| 2026-10-20 | — | commit-review corrections applied (addendum 03 r2: A3.7, A3.11, A3.12 → S-10, S-15) | 8b77863 | — | owner go received 16:36; D1 and H1 dispatched |
| 2026-10-20 | D1 | blocked before RED: S-16..S-19 raised by kerf-eval-data | 9f075f0 (cherry-picked to main as efc09db) | — | lead rulings below; D1 unblocked |
| 2026-10-20 | — | lead rulings S-16..S-19 + S-17 split arithmetic committed; D1 unblocked 17:52 | 891d0ee | — | reviewer pins → S-21 |
| 2026-10-20 | H1 | RED gated by lead: task files 0/70 passed, 70 RuntimeError skeleton raises, identical set both seeds; full suite 1328/1398 passed, 70 failed (all H1 modules), 14 excluded, both seeds; compile clean (3 tolerated); diff vs 8b77863 = 8 files, owner block only | 44aa772 | 1 / 99999 | awaiting owner GREEN authorization |
| 2026-10-20 | H1 | GREEN authorized by owner 17:57; relayed to kerf-eval-harness (RED rebased to eb64130, same content) | eb64130 | — | H3 pins on harness_gold / harness_seed added to §7 |
| 2026-10-20 | D1 | RED gated by lead: task files 0/111 passed, 111 RuntimeError skeleton raises (F08.1 ×8, F08.2 ×7, F08.5 ×90, F08.7 ×6), identical failure locations both seeds; full suite 1328/1439 passed, 111 failed (only the 5 D1 test files), 14 excluded, both seeds; compile: exactly the 3 Postgrex warnings; diff vs 891d0ee = 11 files, owner block only, mix.lock unchanged | 6eee017 | 1 / 99999 | awaiting owner GREEN authorization; skeleton bodies raise via apply(:erlang, :error, …) to dodge none() type warnings — accepted, GREEN replaces them |
| 2026-10-20 | H1 | GREEN gated by lead: task files 70/70 both seeds; full suite 1398 passed, 0 failed, 14 excluded, both seeds; diff eb64130..8c96c5a touches 4 lib files only, nothing under test/, mix.lock unchanged; compile: the 3 Postgrex warnings; dialyzer 26 = pre-existing, none in lib/kerf/eval | 8c96c5a | 1 / 99999 | ready for owner merge to main (fast-forward) |
| 2026-10-20 | H1 | merged to main by owner (rebased: RED 4b7e3a8, GREEN df95c9d) and pushed | df95c9d | — | pre-push review → task H1b and H3 header pins (S-22) |
| 2026-10-20 | D1 | RED amendment (frozen manifests refuse mutation, owner finding) re-gated by lead: task files 0/118 passed, 118 RuntimeError skeleton raises (F08.1 ×8, F08.2 ×7, F08.5 ×97, F08.7 ×6), the 7 new tests all raise F08.5, identical failure locations both seeds; full suite seed 1: 1328/1446 passed, 118 failed (only the 5 D1 files), 14 excluded; seed 99999: 1327/1446, 119 failed = the 118 D1 + `test/monitor/alerting_test.exs:135` (capture_log race on a 100 ms sleep; the file passes on 7 consecutive reruns at seed 99999 — pre-existing flake, same class as the process_health item in addendum 02 accepted_gaps, hygiene sitting); compile: exactly the 3 Postgrex warnings; diff 6eee017..964ff43 = 1 test file (+62), nothing under lib/, mix.lock unchanged | 964ff43 | 1 / 99999 | awaiting owner GREEN authorization |
| 2026-10-20 | D1 | GREEN authorized by owner 20:29 on 964ff43; relayed to kerf-eval-data with the owner's implementation decisions (nothing raises; save tmp+rename, load rebuilds structs; seed_s/uniform_s threaded; one private frozen guard; Synthetic timestamps strictly before frozen_at) and the S-21 pins | 964ff43 | — | alerting_test flake accepted as pre-existing (hygiene list, with process_health) |
| 2026-10-20 | H2 | dispatched to kerf-eval-harness (Opus) 20:29; branch to be rebased onto main (H1 already there) | — | — | RED expected: test(RED): SPEC_H H2 — scoring and report (F09.1–F09.7, F07.3) |
| 2026-10-20 | D1 | GREEN blocked 20:33 by a RED self-contradiction found by kerf-eval-data (reported, not worked around): `test/eval/manifest_test.exs:105` adds synthetic items to `Synthetic.build()` (frozen) and expects `{:ok, …}`, while the owner's amendment at `:701` requires `{:error, [{:frozen, …}]}` on the same call. No lib satisfies both; GREEN tops out at 117/118. Proposed one-word RED amendment: line 106 → `Synthetic.build(frozen: false)` (test intent — nil doc_ids never collide — unchanged). Lead verified both tests at 964ff43; GREEN commit held | 964ff43 | — | awaiting owner: amend RED then GREEN, or commit GREEN at 117/118 with the test flagged |
| 2026-10-20 | D1 | RED amendment #2 (`frozen: false`, one line) re-gated by lead: task files 0/118, 118 RuntimeError skeleton raises (F08.1 ×8, F08.2 ×7, F08.5 ×97, F08.7 ×6), identical locations both seeds; full suite seed 1: 1328/1446 passed, 118 failed (D1 files only), 14 excluded; seed 99999: 1326/1446, 120 failed = 118 D1 + `alerting_test.exs:135` + `process_health_test.exs:90` (both accepted monitor flakes, addendum 02 / hygiene list); compile: the 3 Postgrex warnings; diff 964ff43..990fbed = 1 test line, nothing under lib/, mix.lock unchanged | 990fbed | 1 / 99999 | passed; RED amendment #3 (sha256 tuple, S-23b) dispatched 20:43, re-gate folds both; GREEN D1 authorization carries to that sha |
| 2026-10-20 | D1 | RED amendment #3 (sha256 ok/error tuple, +5/−1 in the test file) re-gated by lead: task files 0/119, 119 RuntimeError skeleton raises (F08.1 ×9, F08.2 ×7, F08.5 ×97, F08.7 ×6), identical locations both seeds; full suite seed 1: 1328/1447 passed, 119 failed (D1 files only), 14 excluded; seed 99999: 1327/1447, 120 failed = 119 D1 + accepted `alerting_test.exs:135` flake; compile: the 3 Postgrex warnings; nothing under lib/, mix.lock unchanged | 7bdcc9b | 1 / 99999 | passed; GREEN D1 authorization relayed for this sha 20:57 — executor committing GREEN on top |
| 2026-10-20 | H2 | RED gated by lead: branch rebased onto main (parent 4c9edd4); 4 new files (2 skeletons, 2 test files, +1472); task files 70/145 passed (the 70 H1 tests), 75 RuntimeError skeleton raises (F09.1 ×35, F09.2 ×14, F09.8 ×9, F09.7 ×6, F09.3 ×3, F09.5 ×3, F09.6 ×3, F09.4 ×1, F07.3 ×1), identical failure locations both seeds; full suite seed 1: 1398/1473 passed, 75 failed (score_test 66, report_test 9), 14 excluded; seed 99999: 1397/1473, 76 = 75 + accepted `process_health_test.exs:90` flake; compile: the 3 Postgrex warnings, 0 test-compile warnings; mix.lock unchanged; skeletons use the same apply(:erlang, :error, …) form accepted for D1 | 5077b60 | 1 / 99999 | awaiting owner GREEN authorization; contract choices under S-25 need the owner's yes/no before GREEN (one of them, F09.1 nil-baseline → pending, changes gate semantics) |
| 2026-10-20 | D1 | GREEN gated by lead: task files 119/119 both seeds; full suite seed 1: 1447/1447, 14 excluded; seed 99999: 1446/1447, the one failure the accepted `alerting_test.exs:135` flake; diff 7bdcc9b..ff0b859 = 5 lib files under lib/kerf/eval/manifest* (+948/−50), nothing under test/, mix.lock unchanged, no file outside the owner block since 891d0ee; compile: the 3 Postgrex warnings; format clean; dialyzer 26 = pre-existing baseline, 0 lines mentioning lib/kerf/eval | ff0b859 | 1 / 99999 | ready for owner merge to main; S-24 decisions and S-26 defect for owner acceptance/triage |
| 2026-10-20 | D1 | GREEN accepted by owner 21:11, S-24 accepted in full; owner merging eval/data to main | ff0b859 | — | D1b dispatched (option (a)); D2/D3/D4 after the merge |
| 2026-10-20 | H2 | S-25 ruled (S-25b): (1)–(4), (6)–(11) accepted; (5) overturned on F09.1; RED amendment relayed 21:12 | — | — | re-gate the amendment sha, then GREEN H2 authorized on it |
| 2026-10-20 | D1b | dispatched to kerf-eval-data 21:12 (stays on Opus) | — | — | RED expected: test(RED): SPEC_H D1b — question_set definition shape is a violation, never a raise (F08.1, F08.2) |
| 2026-10-20 | H2 | RED amendment (S-25b, score_test.exs +33/−2) re-gated by lead: task files 70/147 passed, 77 RuntimeError skeleton raises (F09.1 ×37, others unchanged), identical locations both seeds; full suite 1398/1475 both seeds, only the 77; compile: the 3 Postgrex warnings; nothing under lib/, mix.lock unchanged. Executor correction: no 5077b60 test asserted the old nil-baseline reading — the two existing "pending" tests already used easy ≥ 0.90; two "fail" cases added | 26a5977 | 1 / 99999 | passed; GREEN H2 authorized on this sha (owner 21:11), relayed 21:20 |
| 2026-10-20 | D1b | RED gated by lead: branch at main's tip ceb7aa9 (owner merge rewrote D1 shas: ff0b859 → ceb7aa9, 7bdcc9b → 0553093, 990fbed → cf2036c); 1 test file +37; task files 119/122 passed, 3 failures, identical both seeds; **failure kind is not a skeleton raise**: 2 × Protocol.UndefinedError from `value not in options` (manifest.ex:324) and 1 × ArgumentError from `length(levels)` (manifest.ex:336), both inside lib called from the test body — the S-26 defect itself, lib unchanged (lead pre-authorized this kind for D1b in the dispatch; a §9 exception recorded here); full suite 1517/1520 both seeds, only the 3; compile: the 3 Postgrex warnings; mix.lock unchanged. Ran on Sonnet 5.5 (owner switched the session before dispatch) | 3c8e0ce | 1 / 99999 | awaiting owner GREEN authorization |
| 2026-10-20 | H2 | GREEN gated by lead: task files 147/147 both seeds; full suite 1475/1475 both seeds, 14 excluded; diff 26a5977..49c2a59 = score.ex + report.ex only (+643/−25), nothing under test/, mix.lock unchanged, nothing outside the owner block since 4c9edd4; compile: the 3 Postgrex warnings; format clean; dialyzer 26 = baseline, 0 in lib/kerf/eval. Executor notes: F09.1 checked easy → nil baseline → overall; metrics use in-schema answers only, out-of-schema counts wrong in accuracy and never raises. Open minor points for a later RED→GREEN: flip_rate by_tier keeps a nil tier as a nil key (accuracy maps it to "unknown"); score/4 needs host_class as an atom (H4 CLI passes the parsed atom); expected_lines assumes header permutations/isolation_items (H3 always writes both) | 49c2a59 | 1 / 99999 | ready for owner merge to main (branch based on 4c9edd4; owner rebases) |
| 2026-10-20 | D1b | GREEN authorized by owner 21:24 on 3c8e0ce; relayed with the binding shape (one manifest-level pass, stops per-item label checks, is_list guards, no rescue); commit wording fix: … (SPEC_H F08.2, S-26) | 3c8e0ce | — | awaiting GREEN sha |
| 2026-10-20 | H1b | RED dispatched to kerf-eval-harness 21:25 on top of 49c2a59 | — | — | RED expected: test(RED): SPEC_H H1b — orders_for/5 pinned to functional Fisher–Yates over :rand.uniform_s (F09.8, S-22) |
| 2026-10-20 | H1b | RED gated by lead: 1 test file (+38/−4), lib untouched (no stub; orders_for/5 still the H1 implementation); task files 146/149 passed, 3 ExUnit assertion failures — the seeded-permutation test, the large-item-index test (both via the new Fisher–Yates `expected_order/5`) and the golden test — same set both seeds; the caller-state purity test already passes (Task isolation) and stands as a regression guard; golden literal checked: 6 orders, index 0 identity, each a permutation of the 6 category labels; full suite 1474/1477 both seeds, only the 3; compile: the 3 Postgrex warnings, 0 test warnings; mix.lock unchanged | f814aad | 1 / 99999 | awaiting owner GREEN authorization |
| 2026-10-20 | D1b | GREEN gated by lead: task files 122/122 both seeds; full suite 1520/1520 both seeds, 14 excluded; diff 3c8e0ce..7c21a54 = manifest.ex only (+53/−9), nothing under test/, mix.lock unchanged, nothing outside the owner block since ceb7aa9; no `rescue` in the file; compile: the 3 Postgrex warnings; format clean; dialyzer 26 = baseline, 0 in lib/kerf/eval. Shape: `question_def_violations/1` once per manifest in sorted key order, reasons :options_not_list / :levels_not_list / :unknown_type / :not_a_definition, placed first (ahead of :question_set_keys), per-item label checks skipped when any; is_list backstop guards in check_label/4; put_label/4 covered via label_violations. Reviewer note: label_violations re-runs the shape check per call (no-op on the validate path) — hoist candidate, not a defect | 7c21a54 | 1 / 99999 | ready for owner merge to main |
| 2026-10-20 | D1b, H2 | merged to main by owner and pushed (rebased: D1b RED 310a4a9, GREEN 1fb9d2f; H2 RED 2335c51 + 1627dcb, GREEN 27e3827); eval/harness rebased, tip 5ce802e = H1b RED (same +38/−4 test-only diff as f814aad); eval/data at 1fb9d2f | 27e3827 | — | D2 and H1b GREEN unblocked |
| 2026-10-20 | H1b | GREEN authorized by owner 22:51 on 5ce802e; relayed to kerf-eval-harness with the binding shape (seed_s from the A3.11 3-tuple, uniform_s threaded Fisher–Yates, no Task/Enum.shuffle/seed/2; questions.ex only; commit `fix: Kerf.Eval.Harness.Questions — functional Fisher–Yates permutations (SPEC_H F09.3, F09.8, S-22)`) | 5ce802e | — | awaiting GREEN sha; H3 after merge |
| 2026-10-20 | D2 | dispatched to kerf-eval-data 22:53 (Sonnet) with the four read-back items (current_database, \d kb_documents, override doc_id match vs id/source_id, raw_text NULL share by source_type); read-back results come to the lead before RED; branch fast-forwards to main first | — | — | RED expected: test(RED): SPEC_H D2 — export query, ssh command, selection, manifest seeding, freeze task (F08.1, F08.7) |
| 2026-10-21 | H1b | GREEN gated by lead: task files 149/149 both seeds; full suite 1599/1599 both seeds, 14 excluded (no monitor flake this time); diff 5ce802e..53bfdb7 = questions.ex only (+13/−8), nothing under test/, mix.lock unchanged, nothing outside the owner block (the plan file shows in `main..53bfdb7` only because main gained 23b995c after the branch point 27e3827); grep: no `Task.`, `Enum.shuffle`, `:rand.seed(`; `:rand.seed_s` + `:rand.uniform_s` threaded in an `Enum.reduce` over `(k-1)..1//-1`; compile: the 3 Postgrex warnings; format clean; dialyzer 26 = baseline, 0 in lib/kerf/eval | 53bfdb7 | 1 / 99999 | ready for owner merge to main (fast-forward on 27e3827); H3 dispatch after the merge |
| 2026-10-21 | D2 | read-back received from kerf-eval-data 22:54 (structural only): (a) default psql DB is the OS-user DB, not the app DB — `kb_documents` is populated only in `kerf_prod` (49 468 rows; `kerf_dev` and `exclaw_test` have the table with 0 rows) → proposed `--db` default `"kerf_prod"`; (b) `\d kb_documents`: all six assumed columns exist (`id uuid`, `source_type varchar(50)`, `source_id varchar(500)`, `source_metadata jsonb`, `raw_text text`, `inserted_at timestamp`), unique index (source_type, source_id); an `email_triage` table exists (FK document_id → kb_documents.id) — see S-27; (c) 134 distinct override doc_ids match `kb_documents.id` 134/134, `source_id` 0 → no S-3; id is uuid, RED pins the `::uuid[]` cast; (d) email is the only source_type, `raw_text IS NULL` 18 304 / 49 468 = 37.0 % — S-8 confirmed | — | — | awaiting owner ruling on (a) and go for RED |
| 2026-10-21 | H1b | merged to main by owner (rebased: RED 1649401, GREEN b605bff) and pushed | b605bff | — | H3 unblocked |
| 2026-10-21 | D2 | owner ruling 06:57: `--db` default `"kerf_prod"` approved (RED asserts the override and the single occurrence); S-27 accepted, owner correcting the private notes; addition: export rows and manifest items carry `source_id` beside `doc_id`; **go D2 RED** relayed to kerf-eval-data | — | — | RED expected on eval/data (ff to b605bff first) |
| 2026-10-21 | H3 | dispatched to kerf-eval-harness 06:58 (Sonnet) with every §7 pin and S-28; first step rebase eval/harness onto main b605bff | — | — | RED expected: test(RED): SPEC_H H3 — harness orchestration over a manifest (F09.3, F09.4, F09.6, F09.8, F08.4) |
| 2026-10-21 | D2 | RED gated by lead: parent 79c0066 (main tip); 6 files +715 (3 lib skeletons, export_test.exs new +571, +1 test each in manifest_test.exs and synthetic_test.exs); task files 122/173 passed, 51 failed — 48 RuntimeError skeleton raises (query ×11, select ×17, parse_args ×8, freeze parse_args ×4, fetch_rows ×3, parse_rows ×3, ssh_command ×2) + 3 in-body assertions (Synthetic `source_id` match, save→load `source_id` round-trip, `kerf_prod` single-occurrence count), identical set both seeds; full suite 1599/1650 both seeds, the 51 failures exactly the task files'; compile: the 3 Postgrex warnings; format clean on touched files; mix.lock unchanged; owner block only; no address outside example.invalid in the diff | cdfdb56 | 1 / 99999 | passed; awaiting owner GREEN authorization — lead recommends the S-30 RED amendment first |
| 2026-10-21 | H3 | RED gated by lead: parent a36bea7 (eval/harness ff-rebased); 2 files +752 (harness.ex 17-line raising skeleton — verified not the executor's throwaway implementation; harness_test.exs 30 tests); task files 151/179 both seeds, 28 failures all `RuntimeError Kerf.Eval.Harness.run/2 not implemented (RED)`, identical set; the 2 passing tests are guards (S-16 order equality, harness.ex grep); full suite 1601/1629 both seeds, failures == the 28; compile: the 3 Postgrex warnings; format clean; mix.lock unchanged; owner block only; no address outside example.invalid. Request observation by `:erlang.trace_pattern` + `:erlang.trace(pid, …, [:call, :set_on_spawn])` on a spawned runner: node-global pattern checked — tests inside one module run serially under `async: true` and no other module traces these adapters, so no cross-talk | 78e5508 | 1 / 99999 | passed; awaiting owner GREEN authorization; executor choices (a)–(e) accepted as S-31 |
| 2026-10-21 | D2 | owner ruling 09:10: S-30 accepted with a third item (malformed `--since` → `{:error, _}`); S-29 (A) accepted with a D4-time follow-up RED; RED amendment (test file only, on top of cdfdb56) relayed to kerf-eval-data 09:12; GREEN D2 authorized on the amended sha once re-gated | — | — | awaiting "RED D2 <sha>" for re-gate |
| 2026-10-21 | H3 | GREEN authorized by owner 09:10 on 78e5508 (S-28, S-31 accepted); relayed to kerf-eval-harness 09:12 with the binding shape (harness.ex only; try/rescue + catch :exit around `Kerf.Decide.ask/3`; seed slots; isolation order; H4 `--limit` help-text pin recorded in §7) | 78e5508 | — | awaiting GREEN sha; H4 after merge |
| 2026-10-21 | D2 | RED amendment (S-30, test file only, +53 in export_test.exs, 7 new tests) re-gated by lead: task files 122/180 both seeds, 58 failures = 55 RuntimeError skeleton raises (the 7 S-30 tests all on the parse_args skeleton) + the 3 known in-body assertions, identical set; full suite 1599/1657 both seeds, failures == task files; compile: the 3 Postgrex warnings; format clean; mix.lock unchanged; no address outside example.invalid. Note: the "SQL/ssh never see them" clause is pinned at the parse_args/1 layer (an error return before any fetch); the mix task wiring parse → fetch is GREEN's. Executor hint (symlink/realpath resolution for the repo-root refusal) declined for GREEN — untested; candidate for a later RED | 13be0b9 | 1 / 99999 | passed; GREEN D2 authorization relayed 09:16 (owner pre-authorized on the amended sha) |
| 2026-10-21 | H3 | GREEN gated by lead: task files 179/179 both seeds; full suite 1629/1629 both seeds, 14 excluded; diff 78e5508..204c589 = harness.ex only (+321/−6), nothing under test/, mix.lock unchanged, nothing outside the owner block (the plan file in `b605bff..204c589` is main's own commits); compile: the 3 Postgrex warnings; format clean; dialyzer 26 = baseline, 0 in lib/kerf/eval. Shape read by the lead: `with` over ready_for_run? → manifest_sha256 (case, `{:error, {:manifest_sha256, _}}`) → adapter_info (`%{} when not is_struct` else `{:error, {:invalid_header, _}}`) → Questions.from_question_set; single seam `ask/2` at harness.ex:264-283 builds extras by `case ctx.adapter` (Oracle → harness_gold, Random → harness_seed, `_real -> []`), calls `Kerf.Decide.ask/3` once inside try/rescue + catch :exit; no other `.ask(`; header adapter = `inspect(ctx.adapter)`. Executor header choices: run_id `<set_id>-<last module segment lowercased>-s<seed>-<started_at>`; timestamps UTC ISO8601 to the second; host from `:inet.gethostname/0`; kerf_git_sha `git rev-parse --short HEAD` or `"unknown"` (release); latency_skipped for Oracle/Random or skip_latency. Executor notes for an H4-time RED (not fixed in GREEN): (1) `manifest_path` nil raises inside `Manifest.sha256/1` (`File.read(nil)`) before the wrapper — pin nil → `{:error, {:manifest_sha256, _}}`; (2) adapter_opts are written verbatim into the header — a future credential-bearing adapter needs redaction; (3) run_id contains colons — H4 must not use it as a filename; (4) `Keyword.fetch!(opts, :adapter)` raises on a missing adapter (lead note; CLI always passes one) | 204c589 | 1 / 99999 | ready for owner merge to main (fast-forward on b605bff); H4 dispatch after the merge |
| 2026-10-21 | D2 | GREEN gated by lead: task files 180/180 both seeds; full suite 1657/1657 both seeds, 14 excluded; diff 13be0b9..53204ae = 5 lib files (+485/−30: export.ex, kerf.eval.export.ex, kerf.eval.freeze.ex, manifest/item.ex +source_id/+seed_category, manifest/synthetic.ex; manifest.ex untouched since `@item_fields` derives from the struct), nothing under test/, mix.lock unchanged, nothing outside the owner block since 79c0066; `"kerf_prod"` once in lib (`@default_db`, export.ex:44); name pattern `~r/\A[A-Za-z0-9][\w.-]*\z/` at export.ex:48; the SQL's only `now()` is `now() at time zone 'UTC'`; compile: the 3 Postgrex warnings; format clean on the 5 files. **Dialyzer 38 vs the 26 baseline — S-32 for the owner:** the 12 new are all in the two new mix task files (export 7, freeze 5), kinds `callback_info_missing (Mix.Task)` and `unknown_function` for `Mix.raise/1`, `Mix.shell/0`, `Mix.Task.run/1` — the same kinds as `kerf.eval.replay.ex` (5) and every other `lib/mix/tasks/*.ex` in the baseline (`:mix` not in the PLT); 0 lines mention lib/kerf/eval. Executor behaviour beyond the tests (reported, untested): the export task refuses to overwrite an existing `--out`; `--raw` writes raw rows as JSONL; `--hashes-out` is parsed and validated but not written (notice printed; D3 wires `PII.write_hashes/2`); `query/1` and `fetch_rows/1` re-validate host/db/since/ids; freeze task = load → `freeze/4` → atomic save. Later-RED candidates: realpath/symlink resolution for the repo-root guard, `chmod 600` on `--raw` output, `ceil(share*target)` float rounding | 53204ae | 1 / 99999 | passed except S-32 (dialyzer count); ready for owner merge once S-32 is ruled |
| 2026-10-21 | D2 | owner 09:23: S-30 follow-up — one more RED in the chain before GREEN (core function run with a recording runner and each bad `--host`/`--db` → `{:error, _}`, runner and `query/1` never invoked; GREEN addition: `ssh_command/3` validates host/db with the same pattern). GREEN 53204ae is superseded (kept as branch `d2-green-wip`, to be cherry-picked onto the new RED and squashed into one GREEN commit); S-32 ruling still pending. Lead design S-33 relayed 09:26 | — | — | awaiting "RED D2 <sha>" (amendment #2) |
| 2026-10-21 | D2 | RED amendment #2 (S-30 follow-up / S-33) re-gated by lead: parent 13be0b9 (branch reset, GREEN kept as `d2-green-wip` = 53204ae); test file +89 (6 tests: three `ssh_command/3` refusals; `run/2` bad host/db → `{:error, _}` with runner and query_fn counts 0, benign argv → `{:ok, %{manifest_path, rows: 2}}` with each seam once and a loadable 2-item manifest, malformed argv → error before any seam), lib +7/−1 = raising `run/2` skeleton + two `@spec`s; task files 122/186 both seeds, 64 failures = 61 RuntimeError skeleton raises + the 3 known assertions, identical set; full suite 1599/1663 both seeds, failures == task files; compile: the 3 Postgrex warnings; format clean; mix.lock unchanged; no address outside example.invalid | 74a0198 | 1 / 99999 | passed; GREEN D2 go relayed 09:30 (cherry-pick + run/2 + ssh_command guard, one commit) |
| 2026-10-21 | D2 | GREEN (replacing 53204ae; one commit on 74a0198) gated by lead: task files 186/186 both seeds; full suite 1663/1663 both seeds, 14 excluded; diff 74a0198..c7c4f66 = 5 lib files (+521/−33), nothing under test/, mix.lock unchanged, nothing outside the owner block since 79c0066; `"kerf_prod"` once (export.ex:44); compile: the 3 Postgrex warnings; format clean on the 5 files. Read by the lead: `ssh_command/3` runs `check_name/2` on host and db against `@name_pattern` before building the list and returns `{:error, {:invalid_name, :host | :db}}` otherwise; `fetch_rows/1` goes through `ssh_command/3` (so a bad name stops before the runner) and takes `opts[:query_fn]`; `run/2` = parse_args → refuse existing `--out` → Overrides.load → clients → overrides sha → `query_fn` once → fetch_rows (SQL cached, runner seam) → write_raw → select → build_manifest → save; the mix task is boilerplate + `Export.run(argv, [])` + printing. Dialyzer 35 = baseline 26 + 9, all the S-32 class in the two task files (export 4, freeze 5; the export task shrank), 0 in lib/kerf/eval | c7c4f66 | 1 / 99999 | passed except S-32 (owner ruling); ready for owner merge to main (branch cdfdb56 → 13be0b9 → 74a0198 → c7c4f66 on 79c0066; owner rebases); D3 dispatch after the merge |
| 2026-10-21 | D2, H3 | merged to main by owner and pushed (rebased: D2 RED f1ee0d9 + 0c20754 + 1eae1e6, GREEN e9b9454; H3 RED 14ea86f, GREEN 8e7db9b); S-32 closed by owner commit 1cd8c99 (`plt_add_apps: [:mix, :ex_unit]`), new dialyzer baseline 4, gate rule 0 new over 4; plan commits through 97df7e9 pushed; `d2-green-wip` deleted; both executor branches already fast-forwarded onto the merged code | 1cd8c99 | — | D3 and H4 unblocked |
| 2026-10-21 | D3 | dispatched to kerf-eval-data 11:25 (Sonnet): ff onto 1cd8c99; `manifest/pii.ex` skeleton + `Export.run/2` writes `--hashes-out`; five RED groups (address_hashes on Synthetic, write/read round-trip, scan on tmp files, KERF_EVAL_HASHES notice-and-skip, export wiring through the D2 seams) | — | — | RED expected: test(RED): SPEC_H D3 — PII guard: address hashes, scan, KERF_EVAL_HASHES notice, --hashes-out written (F08.6); the real-list scan skips with its notice until H-5 |
| 2026-10-21 | H4 | dispatched to kerf-eval-harness 11:26 (Sonnet): ff onto 1cd8c99; `harness/cli.ex`, `harness/selftest.ex`, `mix/tasks/kerf.eval.decide.ex`; nine pins (help-text `--limit` semantics, repo-root refusal per flag, nil manifest_path / missing adapter / missing seed → error, file name from `--out`, limited run → all gates pending, latency_skipped for random/oracle, `--allow-remote` reading S-34, bad alias / bad seed / missing flags → error, self-test on `Synthetic.build(n: 60, pairs: 6)`) | — | — | RED expected: test(RED): SPEC_H H4 — mix kerf.eval.decide CLI, repo-root refusal, --limit help text, F09.9 self-test (F09.9, F09.8, F09.5) |
| 2026-10-21 | D3 | RED gated by lead: parent 1cd8c99 (eval/data ff'd); 3 files +275 (pii.ex skeleton 55 lines with `@spec`s and a `header/0` constant, pii_guard_test.exs 193, export_test.exs +27 = 2 `Export.run/2` tests); task files 65/79 both seeds, 14 failures = 13 RuntimeError skeleton raises (F08.6 scan/2, read_hashes/1, address_hashes/1, write_hashes/2) + 1 in-body `File.Error` from `File.read!` on the unwritten `--hashes-out` file (export_test.exs:678 — fails for the right reason, but the kind is a raise in the assert's right-hand side, not an assertion; nit, see notes), identical set; the two `KERF_EVAL_HASHES` tests pass by design (variable unset → notice `PII guard SKIPPED: KERF_EVAL_HASHES is not set` printed once, scan skipped); full suite 1696/1710 both seeds, 14 excluded, failures == task files; compile: the 3 Postgrex warnings; format clean on the 3 files; mix.lock unchanged; nothing under priv/; only `example.invalid` addresses (two upper-cased variants for the normalisation tests) | 62fdb94 | 1 / 99999 | passed; awaiting owner GREEN authorization — lead recommends one small RED amendment first: (a) `assert File.exists?(hashes_out)` before the `File.read!` so the failure is an assertion; (b) `scan/2` skips an unreadable file without raising (executor's own untested note); (c) `scan/2` output never contains an `@` token (structural: it is `[{file, line}]`) |
| 2026-10-21 | H4 | RED gated by lead: parent 1cd8c99 (eval/harness ff'd); 5 files +852 (3 skeletons: cli.ex 25, selftest.ex 15, kerf.eval.decide.ex 16; cli_test.exs 622, selftest_test.exs 174); task files 0/44 passed + 12 invalid both seeds, identical set: 39 RuntimeError skeleton raises (parse_args/1 ×28, CLI.run/1 ×9, help/1 ×2), 1 assertion (`assert_raise Mix.Error` met the task skeleton's RuntimeError), 4 pin-3 failures raised inside live lib — `KeyError :adapter`, `KeyError :seed` (harness.ex:37/:84 `Keyword.fetch!`), 2× `FunctionClauseError` in `IO.chardata_to_string/1` (`File.read(nil)` via `Manifest.sha256/1`) — the defect the pin names, lib unchanged (D1b-class §9 exception, pre-authorized at dispatch); the 12 invalid are the selftest module whose `setup_all` runs `Selftest.run/2` once (the skeleton raise invalidates the module in RED; in GREEN an `{:error, _}` result would fail the tests in-body, not the setup — accepted as a RED-only artefact, second §9 exception recorded); full suite 1693/1737 both seeds, 12 invalid, 14 excluded, failures == task files; compile: the 3 Postgrex warnings; format clean on the 5 files; mix.lock unchanged; owner block only; no address outside example.invalid (hosts: `localhost.evil.example`, `127.0.0.1.example.invalid`). Pins verified in the file: both help-text phrases (cli_test.exs:437-438), repo-root refusal for absolute/relative/cwd-itself paths naming the flag, exact host match with spoof hosts refused (:238-239), unknown `Elixir.*` adapter creates no atom (:213), `Elixir.Enum` refused. Executor ran on Opus 5.5 (session model, dispatch said Sonnet) | 5c0531f | 1 / 99999 | passed; awaiting owner GREEN authorization and the S-34 ruling (executor deviates from the lead's loopback-only reading: tailnet 100.64/10 accepted, mirroring the HTTP adapter's own policy) |
| 2026-10-21 | H4 | GREEN authorized by owner 11:48 on 5c0531f; S-34 ruled = adapter mirror (loopback + tailnet without the flag, every other host refused unless `--allow-remote`, exact host match), no amendment; relayed to kerf-eval-harness 11:50 with the binding shape (cli.ex, selftest.ex, task file, harness.ex pin-3 errors only; `--allow-remote` forwarded only as `allow_remote: true`) | 5c0531f | — | awaiting GREEN sha |
| 2026-10-21 | D3 | owner 11:48: RED amendment first (hashes-file existence assertion; `scan/2` skips unreadable files; no address in scan output), GREEN D3 authorized on the amended sha after re-gate; relayed to kerf-eval-data 11:51 | — | — | awaiting "RED D3 <sha>" (amendment) |
| 2026-10-21 | D3 | RED amendment (test files only on 62fdb94, +27: existence assertion before `File.read!`, `scan/2` skips a mode-0o000 file next to a readable hit with the mode restored in `on_exit`, result carries no address) re-gated by lead: task files 65/81 both seeds, 16 failures = 15 RuntimeError skeleton raises (scan/2 ×7, address_hashes/1 ×3, read_hashes/1 ×3, write_hashes/2 ×2) + 1 assertion (`assert File.exists?(hashes_out)`), identical set; full suite 1696/1712 both seeds, 14 excluded, failures == task files; compile: the 3 Postgrex warnings; format clean; nothing under lib/, mix.lock unchanged; no address outside example.invalid. Executor caveat: as root the 0o000 file stays readable — the locked file holds no address, so the assertion holds either way | 4072b1e | 1 / 99999 | passed; GREEN D3 go relayed 11:52 (owner pre-authorized on the amended sha) |
| 2026-10-21 | D3 | GREEN gated by lead: task files (pii_guard, export, manifest suites) 205/205 both seeds; full suite 1712/1712 both seeds, 14 excluded; diff 4072b1e..8e89124 = 3 lib files (+133/−18: pii.ex, export.ex, kerf.eval.export.ex), nothing under test/, mix.lock unchanged, nothing outside the owner block since 1cd8c99; compile: the 3 Postgrex warnings; format clean; dialyzer 4 = the new baseline exactly (the 4 pattern_match_cov lines), 0 in lib/kerf/eval and lib/mix. Read by the lead: `scan/2` walks via `File.lstat` and uses only `:regular` and `:directory` entries (no symlink followed, loops impossible), skips a file whose first 8192 bytes contain a NUL (`:binary.match(probe, <<0>>)`), skips unreadable files, unlistable directories and missing roots, hits are `{file, line}` only; `hash_addresses/1` (trim, downcase, dedupe, sort) is shared by `address_hashes/1` and the export; `Export.run/2` writes `--hashes-out` from the selected rows' `from` **before** `Manifest.save`, a failed write returns `{:error, {:hashes_write_failed, _}}` with no manifest left behind; `read_hashes/1` skips blank/`#` lines, `{:error, {:line, n, :not_a_sha256_hex}}` on a bad line, result deduplicated and sorted; the mix task's notice is gone. The real guard still prints its skip notice (KERF_EVAL_HASHES unset until H-5) | 8e89124 | 1 / 99999 | ready for owner merge to main (eval/data = 62fdb94 → 4072b1e → 8e89124 on 1cd8c99, fast-forward); D4 dispatch after the merge and H-9 |
| 2026-10-21 | H4 | GREEN gated by lead: task files (harness_test, harness/, adapters/) 235/235 both seeds; full suite seed 99999 1749/1749; seed 1 first run 1745/1749 — the 4 failures all `test/agents/email_triage/routing_config_test.exs` watcher tests (`assert_receive` after 5000 ms on a `FileSystem` fsevents subscription), disjoint from the H4 diff; the file passes 3/3 reruns at 867f50d and at main 1cd8c99; full-suite seed 1 rerun 1749/1749 — recorded as a load-timing flake (executor suites were running concurrently), added to the hygiene list with alerting/process_health; 14 excluded; diff 5c0531f..867f50d = harness.ex (+20/−5 pin 3), cli.ex, selftest.ex, kerf.eval.decide.ex (+628/−25), nothing under test/, mix.lock unchanged, owner block only; compile: the 3 Postgrex warnings; format clean; dialyzer 4 = baseline, 0 in lib/kerf/eval and lib/mix (the task file included). Read by the lead: `required_option/2` → `{:error, {:missing_option, :adapter | :seed}}`, `manifest_sha256(nil)` → `{:error, {:manifest_sha256, :no_manifest_path}}`, no `Keyword.fetch!` left; `local_host?/1` at cli.ex:265-275 = exact `"localhost"` or `:inet.parse_address` in 127/8, 100.64/10, ::1, called once from `base_url/2` after the scheme/host check; `allow_remote` forwarded only as `allow_remote: true` (cli.ex:236-240), refused for random/oracle via `@adapter_flags`. **Executor choices for owner acceptance:** (1) `Selftest` scores each run's *normalized* file read back from disk (selftest.ex:73-86) so two oracle reports are byte-identical whichever second they start in (F09.8, S-25(10)); cost: the self-test's report.md `- started:` line is empty, raw run files keep `started_at`, the CLI `score` subcommand is unchanged — one intermittent 8-failure selftest run on seed 99999 before this change, not reproducible after; (2) the mix task runs `app.config` then `Application.ensure_all_started(:req)` (Finch pool for the HTTP adapter; the Kerf app stays stopped) — verified by the executor against a refused port (37 `:econnrefused` error lines with `--limit 1`), not covered by a test. Smoke run of the default self-test (244 items) ≈ 1.4 s: oracle every gate pass + F09.5 skipped; random F09.1/2/3/4/7 fail, F09.6 pass, F09.5 skipped — **random's scaled F09.2 came out "fail" on the synthetic set, where S-2 predicted pass** (reported, not asserted; harmless under the ruling, owner to know before filing H-9). Cosmetic: a Decide telemetry "Failed to lookup telemetry handlers" warning (telemetry app not started). Reviewer note: repo-root refusal compares `Path.expand/1` output, no symlink resolution (same later-RED candidate as Export) | 867f50d | 1 / 99999 | ready for owner merge to main (eval/harness = 5c0531f → 867f50d on 1cd8c99, fast-forward); then H-9 |
| 2026-10-22 | D3, H4 | merged to main by owner and pushed (rebased: D3 RED deb441e + 2f812c9, GREEN cbf4ab1; H4 RED 3e7b6d0, GREEN 92b6e07); plan commits through 1befce4 pushed; **H-9 done**: self-test passed on main 92b6e07, oracle report sha256 `d332ce14…7945`, summary filed in the private tree — step-3 entry gate met. Owner adds task H4b (S-35) before any F10 run | 92b6e07 | — | D4 and H4b dispatched |
| 2026-10-22 | D4 | dispatched to kerf-eval-data 09:50 (Sonnet): ff `eval/data` (at cbf4ab1) onto 92b6e07; label page + one guarded router block + `:eval_ui` in dev/test config; the S-29 follow-up (seed-aware `put_label/4` source) and S-35(d) (0o600 hashes file) ride in the same RED/GREEN | — | — | RED expected: test(RED): SPEC_H D4 — labelling page, :eval_ui mounting, seed-aware label source, 0o600 hashes file (F08.1, F08.2, F08.3, F08.4, S-29, S-35) |
| 2026-10-22 | H4b | dispatched to kerf-eval-harness 09:50 (Sonnet): branch already at 92b6e07; `--force` on `run`, checked sink writes with `{:error, {:write_failed, path, reason}}` and no `run_end`, `run/2` with an injected starter raising `Mix.Error` | — | — | RED expected: test(RED): SPEC_H H4b — run refuses an existing --out unless --force, sink write errors abort without run_end, :req start failure raises (F09.8, F09.6, S-35) |
| 2026-10-22 | D4 | RED gated by lead: parent 92b6e07 (`eval/data` was already there); 8 files +469/−5 (label_page.ex 21-line skeleton with a real `menu_link/2`, mount/render raise; router.ex +6/−1 = one `@eval_pages` `compile_env` block appended with `++ @eval_pages`; dev.exs and test.exs +4 each, the `:eval_ui` line; label_page_test.exs 342, eval_ui_config_test.exs 34; manifest_test.exs +54/−5; pii_guard_test.exs +7); task files (app started) 109/128 both seeds, 19 failures = 16 `RuntimeError not implemented (SPEC_H F08.2 mount/3)` + 3 ExUnit assertions (the two red S-29 tests, the 0o600 test), identical set; the 2 config tests pass by design; full suite seed 1 1772/1791 (failures == task files), seed 99999 1771/1791 = the 19 + accepted `alerting_test.exs:135` flake; compile: the 3 Postgrex warnings; mix.lock unchanged; owner block only; addresses in the diff: `a@example.invalid`, `synthetic@example.invalid` only. Format: the 5 new/changed files clean; router.ex, dev.exs, test.exs fail `--check-formatted` **on main already** (pre-existing; the executor reverted an accidental repo-wide reformat, the diff adds formatted lines only) — recorded, not a gate failure. **For owner acceptance:** (1) the executor replaced the D1 test "keeps an adjudicated category source (F08.7)" (nil `seed_category`, source `"adjudicated"` → stays) because the S-29 rule inverts that case; the three tests now pin seeded+equal → `"adjudicated"`, seeded+differing → `"new"` with `seed_category` unchanged, nil seed + source `"adjudicated"` → `"new"` (the dispatch wrongly called that one green today). (2) Page contract pins: events via `render_hook` — `save_label` `%{"item_id", "labels" => 5 string fields}`, `save_tier` item_id/tier/tier_reason, `save_language` item_id/language, `add_synthetic` of_item_id + `"state"` map, `mark_pair` pair_id/item_a/item_b/fact; text: progress line `"N of M labelled"`, a notice naming `KERF_EVAL_MANIFEST` when the path is nil, violation codes rendered as atom names; DOM: `#item-<id> select[name='labels[category]'] option[selected]` for the seed pre-fill. (3) urgency `"abc"` → `:label_wrong_type` (an unparseable value passes through unconverted, never crashes or coerces) | cbb4649 | 1 / 99999 | passed; awaiting owner GREEN authorization |
| 2026-10-22 | H4b | RED received 09:55 ("RED H4b 2d9f1f2", parent 92b6e07): 247 tests, 236 passed, 11 failed both seeds per the executor (skeleton raises on `CLI.file_sink/2` and `Decide.run/2`, the rest assertions); executor finding → S-35 note (5); lead gate queued behind D4's | 2d9f1f2 | — | lead gate pending |
| 2026-10-22 | H4b | RED gated by lead: parent 92b6e07; 5 files +225 (two skeletons: `CLI.file_sink/2` +4 with `@spec`, `Decide.run/2` +7 with `@spec`; cli_test.exs +93, harness_test.exs +55, decide_task_test.exs new 66); task files (harness_test, harness/, adapters/, `--no-start`) 236/247 both seeds, 11 failures = 3 RuntimeError skeleton raises (file_sink ×2, run/2 ×1) + 8 ExUnit assertions (3 sink-abort tests in harness_test — third call, header, run_end; `--force` parsed; three existing-`--out` tests — refused before manifest load with bytes unchanged, refused over a ready manifest, replaced with `--force`; `assert_raise Mix.Error` met the skeleton's RuntimeError), identical set; no `MatchError` (the task tests go through `run/2`, live line 28 never runs); the existing `--force`-refused-elsewhere guard already passes (strict OptionParser); full suite 1769/1780 both seeds, failures == task files, no flake; compile: the 3 Postgrex warnings; format clean on all 5 files; mix.lock unchanged; owner block only; no address in the diff; every test path under `System.tmp_dir!()`. Executor's IO.binwrite finding → S-35 note (5), lead ruling (i) | 2d9f1f2 | 1 / 99999 | passed; awaiting owner GREEN authorization (and the S-35(5) veto window) |

### 10.2 Spec disagreements and corrections (stop and write here; never diverge silently)

- **S-1 (owner-directed, → addendum 03)** F08.6 "the private `~/Projects/kerf/docs/eval/` on the Mac"
  reads as `~/Projects/kerf/private/eval/` (no `docs/` tree is created). The Spark side
  `~/eval/decide/` is unchanged. Recorded 2026-10-20 at the owner's instruction.
- **S-2 (decided by owner 2026-10-20, → addendum 03)** F09.9 requires the uniform-random adapter
  to *fail* F09.2, but F09.2's gate is on *post-scaling* ECE. Temperature scaling of an
  uninformative adapter drives `T → ∞`, probabilities → `1/K`, and ECE → ≈ 0 on both Noul and
  Choice, so random is expected to **pass** scaled F09.2 (while failing F09.1, F09.3, F09.4, F09.7
  and raw ECE). **Ruling (addendum 03 text):** "F09.9: random must fail F09.1, F09.7 and RAW
  F09.2; scaled F09.2 for random is reported, not asserted; oracle passes every gate except F09.5
  (skipped)." H2 implements the F09.2 gate as written (scaled). H4 RED proceeds on this basis.
- **S-3 (read-back, D2)** `~/eval/golden-overrides.jsonl` keys are `doc_id`, `label_true`, `note`
  (SPEC_D §7), not `category`. Whether `doc_id` equals `kb_documents.id` is verified by D2's first
  read-only query; mismatch stops D2.
- **S-4 (known)** `Kerf.Provenance` / `Kerf.Gate` (SPEC_G) are not in the tree; the harness builds
  the §4-shaped provenance map, as step 1 did. No action until SPEC_G lands.
- **S-5 (→ addendum 03)** F09.1's second clause ("≥ the current production classifier on the same
  items") has no number yet (spec open question 5). The gate reports `pending` unless
  `--baseline-accuracy` is given; F10 supplies it. The self-test passes `0.5` explicitly.
- **S-6 (→ addendum 03)** F09.2 "the fitted temperature is written to the adapter config": no
  adapter has a temperature option today. The harness writes `temperatures.json`
  (`%{question => T}`); consuming it is F10/F11.
- **S-7 (decision)** Language is not stored anywhere in Kerf. Export assigns a stopword heuristic
  (`language_source: "heuristic"`); the owner corrects in the UI (`"human"`). F08.1 counts are
  computed over the final values.
- **S-8 (decision)** Export excludes `raw_text IS NULL` (37 % of production email documents have no
  body); a Decide state needs content. If the owner wants header-only items in the set, that is a
  spec change.
- **S-9 (decision)** Freeze refuses a language-mix shortfall unless `--allow-mix-shortfall`, and
  records the acknowledgement in the manifest (spec open question 8).
- **S-10 (binding, A3.7 r2)** The PII guard scans `lib/` and `docs/superpowers/plans/` in addition
  to the two directories F08.6 names (superset, stricter). The address-hash list is never committed
  (membership oracle); it lives in the private tree and the guard reads `KERF_EVAL_HASHES`, skipping
  with a printed notice when unset. Corrected after the commit review of 9aa38b0.
- **S-15 (binding, A3.11/A3.12 r2)** Per-request `:rand` seeds are the 3-tuple
  `{seed, item_index * 64 + question_index, order_index}` (4-tuples raise); the isolation token
  expression is parenthesised so 12 hex chars follow `KERF-`. Corrected after the commit review of
  9aa38b0; the freeze seed `{seed, 0, 0}` is unchanged.
- **S-11 (note)** Addendum 01 pre-authorized `config :kerf, Kerf.Decide, adapter:`; it was never
  added and this plan does not need it (the harness passes `adapter:` per call).
- **S-12 (note)** `state_hash` is deferred to step 5 (A2.1); run lines join on `item_id`/`doc_id`.
  F07.3's join is `(model_id, question_name)` via `histograms`, unaffected.
- **S-13 (decided by owner 2026-10-20)** Plan follows the repo convention:
  `docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md`.
- **S-14 (read-back, D2)** The production database name is not asserted anywhere in code or tests;
  D2's executor verifies it with `SELECT current_database();` over read-only ssh and it becomes the
  default of `--db`. The private deployment guide's value is a hint, not a source.
- **S-16 (contradiction, D1 blocked — kerf-eval-data 2026-10-20)** §2.1 types `question_set` as
  `%{String.t() => question_def}` and says "key order = Phase B order"
  (`category, needs_reply, urgency, deadline_present, client`); H1 builds questions "in key order"
  and D1's RED asserts "Phase B keys in order". An Elixir map cannot carry that order: maps of
  ≤ 32 keys iterate in term order. Verified on Elixir 1.20.1/OTP 28 — `Map.keys/1` and `Enum.map/2`
  over that literal both give `["category", "client", "deadline_present", "needs_reply", "urgency"]`,
  and `Jason.decode/1` returns a plain map, so the order is also lost on load. Every consumer of
  "key order" gets alphabetical order. This is the frozen shared interface (manifest struct +
  `manifest.json` schema), so it needs a plan decision, not an executor one. Candidates:
  (a) `question_set :: [{String.t(), question_def}]` (keyword-style list; JSON as an array of
  `{"name", …}` objects); (b) keep the map and add a fixed `QuestionSet.order/0` (the Phase B key
  list) that every consumer iterates instead of the map (JSON object; order is by convention, not
  data); (c) `Jason.OrderedObject` in the struct (decoded with `objects: :ordered_objects`, which
  turns *every* object in the file ordered unless the loader re-maps the rest). Executor's
  recommendation: (b). It is the smallest change, H1 already atomizes "from the fixed Phase B key
  list only", and the manifest stays a plain JSON object. D1 RED waits for the ruling.
- **S-17 (gap, same interface — needs ruling with S-16)** `Manifest.Synthetic.build/1` is
  "frozen", but H3 (`n: 8, pairs: 2`), D4 (`n: 12, pairs: 2`) and H4 (`n: 60, pairs: 6`) ask for
  sizes `freeze/4` refuses (< 200 items, < 20 pairs, and 50 calibration items is impossible at
  n = 8). The plan doesn't say how Synthetic assigns `split` below the freeze thresholds. H4's
  temperature fit needs calibration items at n = 60. Proposed: Synthetic bypasses the freeze
  thresholds but uses the same stratified, seeded selection with
  `calibration = min(50, round(0.2 · eligible))` (eligible = non-pair items), and the default
  (n = 220, pairs = 24) must pass `freeze/4` unchanged, *including* the language mix, so the
  defaults exercise the real freeze path. The D1 RED would assert only the default case plus
  "small n: frozen, validates, ready_for_run?/1 :ok, ≥ 1 calibration item, no pair item in
  calibration".
- **S-18 (ambiguity, D1)** §2.1 "stratified by (language, tier) with largest-remainder rounding"
  doesn't say what the quota population is: all items, or the non-pair items that can actually be
  chosen. The two give different per-stratum quotas. Proposed: the eligible (non-pair) pool,
  `quota_s = 50 · n_s / N_eligible`. The RED would assert each stratum's count ∈
  {⌊quota_s⌋, ⌈quota_s⌉} and a total of exactly 50.
- **S-19 (ambiguity, D1)** `put_label(t, item_id, labels, now)` "sets labelled_at/by" but has no
  `by` argument; the struct comment says `"wido"`. Proposed: a module constant `"wido"` (F08.2
  "assigned by Wido"); the RED would assert `labelled_by == "wido"`. The alternative is a
  `put_label/5` with an explicit labeller, which is an interface change.
- **Lead rulings on S-16..S-19 (kerf-lead 2026-10-20; plan-level, owner may veto before D1 GREEN):**
  - S-16 → **(b)**. `question_set` stays a plain map and a plain JSON object; the order lives only in
    `Kerf.Eval.Manifest.QuestionSet.order/0`; `validate/1` adds `:question_set_keys` (keys must equal
    `order/0` as a set); every consumer iterates `order/0`, never the map. The harness's
    `Kerf.Eval.Harness.Questions` keeps its own compile-time copy of the same list for H1 (which must
    not depend on D1) and H3's RED asserts the two lists are equal. §2.1, §2.3, D1, H3 updated.
  - S-17 → accepted with one correction and a size ruling (owner 2026-10-20). The commit reviewer
    showed the proposal's `min(50, round(0.2 · eligible))` never reaches 50 at the default size
    (34 or 44), so "identical split after `freeze/4`" was unsatisfiable. Reasoning: F08.1 counts
    exported mails and F08.3 counts pairs — they were never the same population — so `n` counts
    real items, `pairs` appends synthetic b-items (default build 220 + 24 = 244 items, 196
    eligible), `counts.total` includes synthetic items and the freeze "≥ 200" uses
    `counts.total − counts.pairs`. `Manifest.assign_split/3` is the shared pure function;
    `freeze/4` calls it with n = 50 after the thresholds; `Synthetic.build/1` skips the thresholds
    and calls it with `n_cal = if real >= 200, do: 50, else: max(1, round(0.2 * eligible))`;
    `frozen: false` returns the unfrozen manifest; the default-size build through `freeze/4` yields
    the identical split. Propagated: H3 10 items, D4 14, H4 66 (§6, §7).
  - S-18 → accepted: quota population is the eligible (non-pair) pool, `quota_s = n · n_s / N_eligible`,
    largest-remainder rounding, each stratum ∈ {⌊quota_s⌋, ⌈quota_s⌉}, total exactly n.
  - S-19 → accepted: module constant `@labelled_by "wido"`; `put_label/4` unchanged; RED asserts it.
  - Worktrees: `mix deps.get` in a fresh worktree is a lock-only fetch and is allowed; `mix.lock`
    must remain unchanged in every RED/GREEN commit (the lead's owner-block check covers it).
- **S-21 (pins from the commit review of 891d0ee, binding for D1)** (1) "real item" means `doc_id`
  non-nil everywhere; `counts.pairs` = number of synthetic items; `:counts_mismatch` fires when
  `counts.total − counts.pairs` ≠ the number of `doc_id`-non-nil items. (2) `assign_split/3` uses
  `:rand.seed_s(:exsss, {seed, 0, 0})` with threaded state, never `:rand.seed/2` (process-global).
  (3) Language-mix thresholds are over `counts.total`; synthetic b-items copy their a-item's language.
- **S-20 (note)** The private notes say executor worktrees live under `.claude/worktrees/<name>/`;
  the actual layout is the plan's sibling directories (`../kerf-eval-data`, `../kerf-eval-harness`).
  Owner to reconcile the private notes; executors follow the plan.
- **S-22 (owner pre-push review of df95c9d, 2026-10-20; task H1b)** H1 GREEN's `orders_for/5`
  shuffles with `Enum.shuffle/1` inside a short-lived `Task` so the caller's process-dictionary
  `:rand` state is not disturbed. That is correct today but ties F09.8 reproducibility to two things
  outside the spec: `Enum.shuffle/1`'s algorithm (an Elixir implementation detail that may change
  between releases) and a process spawn per call. Ruling: permutations are a functional Fisher–Yates
  over `:rand.uniform_s/2` with the state seeded by `:rand.seed_s(:exsss, {seed, item_index * 64 +
  question_index, order_index})` and threaded through, so an order depends only on OTP's `:exsss`
  and the seed tuple (A3.11). The test suite pins the algorithm with an independent re-statement and
  a golden list. Scheduled after H2 and before H3 so H3's run files are produced by the final
  algorithm (→ addendum 03).
- **S-23 (RED self-contradiction, D1, 2026-10-20)** The owner-side RED amendment 964ff43 ("frozen
  manifests refuse mutation") made the original RED test at `test/eval/manifest_test.exs:105`
  unsatisfiable: it adds synthetic items to `Synthetic.build()` (frozen) and expects `{:ok, …}`,
  while the amendment requires `{:error, [{:frozen, …}]}` on that call. The contradiction came from
  the owner-side amendment, not from the executor, who found it during GREEN and reported it rather
  than editing a test. Owner ruling 20:35: a second one-line RED amendment — line 106 becomes
  `Synthetic.build(frozen: false)`, nothing else — committed before GREEN; the lead re-gates that sha
  on both seeds (118 in-body failures) and the GREEN authorization carries over to it. Lesson for
  addendum 03: an amendment that adds a guard must re-check every earlier test that drives the
  guarded path.
  **S-23b (plan contradiction, same gate, owner-approved 2026-10-20 20:42):** §2.1 typed
  `sha256(path) :: String.t()` while the owner's GREEN rule says nothing raises, so an unreadable
  path had no legal return. The frozen interface changes to
  `sha256(path) :: {:ok, String.t()} | {:error, term()}`. RED amendment #3 (executor, test file
  only, on top of 990fbed): the sha256 test asserts `{:ok, "ba7816bf…15ad"}` and gains "sha256 of a
  missing path is `{:error, _}`", commit `test(RED): SPEC_H D1 — sha256/1 returns an ok/error tuple
  (F08.1)`; folded into the same re-gate as the `frozen: false` fix; GREEN D1 on top. Cause: the plan,
  not the executor. H3 pin added (§7).
- **S-24 (D1 GREEN implementation decisions reported by kerf-eval-data 20:43, beyond the §2.1
  minimum; for owner acceptance at the GREEN gate)** (1) `Manifest.t()` types `counts: counts() |
  nil` and `export: export() | nil` (both default nil in the defstruct; dialyzer otherwise flags
  `Synthetic.build/1` as no_return) — struct fields unchanged. (2) `save/2` errors are
  `{:error, [violation]}`, e.g. `{:write_failed, nil, {:write | :rename, path, reason}}`.
  (3) Extra violation codes: `:frozen`, `:unknown_item`, `:tier_invalid`, `:split_invalid`,
  `:frozen_incomplete`, `:unknown_question_type`, `:file_unreadable`, `:invalid_json`,
  `:schema_version`, `:schema_invalid`, `:write_failed`, `:encode_failed`; freeze: `:unlabelled`,
  `:untiered`, `:too_few_real_items`, `:too_few_pairs`, `:language_mix_shortfall`; ready_for_run?:
  `:not_frozen`, `:labelled_after_freeze`, `:tiered_after_freeze`. (4) `freeze/4` sets
  `export.mix_shortfall_acknowledged = true` only when a shortfall existed and was allowed.
  (5) `Overrides.load/1`: a later line for the same `doc_id` supersedes an earlier one (SPEC_D §7
  appends rulings); blank lines skipped; errors `{:error, {:line, n, reason}}` or
  `{:error, {:file_unreadable, reason}}`. (6) `Language.guess/1` returns `"und"` on a tie for the
  top score as well as on no stopword hit. (7) `Synthetic`: languages follow a fixed 9:6:5 NL/DE/EN
  cycle over real items so the mix holds for every seed (the seed drives labels, tiers and a-item
  choice); the flipped question cycles through `order/0`; timestamps created 08:00Z, labelled and
  tiered 10:00Z, frozen 12:00Z on 2026-10-20; `set_id` = `"synthetic-s<seed>"`. Lead view: none
  contradicts SPEC_H F08 or the addenda; (3)'s codes are a superset of §2.1's minimum.
- **S-25 (H2 RED 5077b60 contract choices pinned in tests where §2.4 fixes names and arities but
  not argument shapes; reported by kerf-eval-harness 20:56; owner yes/no needed before GREEN)**
  (1) `ece/1` takes `[{p, outcome}]`: Noul outcome = `gold == true` with `p = p_yes` (calibration of
  the yes-probability, not of "prediction correct" — the latter would put the oracle's raw ECE at
  ≈ 0.97, contradicting A3.2); Choice outcome = `label == gold` with `p = p_max`. (2)
  `fit_temperature/1` takes `[{probs, gold_index}]` (Noul as `[p, 1−p]`, index 0 when gold true);
  no samples → `1.0`; tests check analytic NLL optima to 1e-6; `apply_temperature(probs, T)`.
  (3) `coverage(lines, expected_count)`; `score/4` computes expected = n × (permutations × 5 + 5)
  + 2 × min(isolation_items, n_eval), n = the first `limit` items in manifest order when a limit
  is set — H3 must produce exactly that line set (matches H3's 368-line example). (4)
  `histograms(%{model_id:, confidences: %{q => [p]}})`, Noul/Choice only, raw eval-split
  identity-order confidences. (5) `gates/1` takes the report minus `gates`; `run` carries `limit`,
  `latency_skipped`, `baseline_accuracy`, `host_class` (`"decoder"|"encoder"|nil`; `score/4`
  takes an atom). `limit` set → every gate pending. **F09.1 with a nil baseline → "pending" even
  when category-easy < 0.90** (A3.3 read literally; a nil baseline never reports "fail" — the
  self-test passes `0.5`, so random still fails there). F09.5 "skipped" when `latency_skipped`,
  "pending" when `host_class` nil. A nil/missing measurement is "fail" (F09.7 with no pairs;
  F09.2/F09.3/F09.4 with a nil value). Thresholds inclusive; F09.5 threshold 150 or 30. (6)
  `accuracy/2` and `contrastive/2` take gold, split, tier and language from the manifest items via
  `Map.get` only (a struct without Access passes); an error line counts as wrong. (7) Splits: flip
  rate, isolation, agreement and latency over every split; accuracy, ECE and histograms eval only;
  temperature calibration only. (8) Flip rate = flips / (item, order) pairs over order 1..5 vs 0,
  by tier and by question; isolation `n` counts distinct items with an isolation line including
  errored ones, means skip error lines; agreement compares main order 0 with separate on the
  predicted label for every qtype; latency nearest-rank via integer ceil, null when
  `latency_skipped`. (9) Coverage keys a line by (item, probe, order_index, question); a duplicate
  key is not answered; `errors` counts lines. (10) `run` excludes `run_id` and `host`; two runs
  differing only in run_id, host, started_at and latency give reports differing only in
  `run.started_at`; the Markdown has exactly one timestamp. (11) Report maps string-keyed;
  `to_json` sorts keys at every depth (incl. a 40-key map) and keeps list order; decodes back to the
  same report. Lead view: (1)–(4), (6)–(11) are the natural reading of §2.4; (5)'s F09.1 rule is a
  semantic choice the owner should confirm or overturn (alternative: "fail" when the easy clause
  fails regardless of the baseline, "pending" only when easy passes and the baseline is nil).
  **S-25b (owner ruling 2026-10-20 21:11 → addendum 04):** (1)–(4), (6)–(11) accepted as pinned.
  (5) overturned on F09.1 only: F09.1 = "fail" when category-easy < 0.90 regardless of the
  baseline; "pending" only when easy ≥ 0.90 and `baseline_accuracy` is nil; "pass" when both
  clauses hold. RED amendment on `eval/harness` (test file only, on top of 5077b60): the one F09.1
  expectation changes to "fail" and a second case is added (easy fails, baseline nil → "fail");
  commit `test(RED): SPEC_H H2 — F09.1 easy clause fails independently of the baseline (F09.1)`;
  lead re-gates; GREEN H2 authorized on that sha. Addendum 04 will cover S-22 through S-26 once H2
  and D1b are green.
- **S-26 (defect found at D1 GREEN by the executor's pre-commit reviewer, confirmed by the
  executor, no test covers it; owner triage)** `Manifest.validate/1` can still raise on a
  hand-edited `question_set`: a choice question whose `"options"` is not a list raises in the `in`
  check; a score question whose `"levels"` is not a list raises in `length/1`. `load/1` validates
  the file's own `question_set`, so a malformed `manifest.json` makes `load/1` raise instead of
  returning `{:error, [violation]}` — a breach of the "nothing raises" rule. Fix: two `is_list`
  guards falling through to `:unknown_question_type`. Not fixed in ff0b859 (GREEN edits no tests;
  the fix needs a RED first). Lead proposal: task **D1b** (same executor, Sonnet) — RED
  `test/eval/manifest_test.exs` gains "load of a manifest whose question_set options is not a list
  returns `{:error, _}`" and the `levels` twin; GREEN adds the guards; gated as any task.
  **Shape (executor note 21:06, lead recommendation):** in ff0b859 `:unknown_question_type` is
  emitted per labelled item with that item's id from `check_label/4`, after the question_set and
  duplicate checks — so a nil-headed assertion would not match it, and one bad question definition
  would produce one violation per item. D1b therefore adds a **manifest-level** question-definition
  shape check, run once before the per-item checks, with a dedicated code
  `:question_def_invalid` (`{:question_def_invalid, nil, {question_key, reason}}`, e.g.
  `{"category", :options_not_list}` / `{"urgency", :levels_not_list}`); the RED asserts
  `{:error, [{:question_def_invalid, nil, {"category", _}} | _]}` at the head of the list and that
  the per-item `:unknown_question_type` is not emitted for that manifest. Alternative (b), a
  membership-only assertion with the existing per-item code, is cheaper but keeps the 244-violation
  behaviour. Add `:question_def_invalid` to the §2.1 code list when D1b is dispatched. A second reviewer note ("nil
  `labelled_at` slips past `ready_for_run?`") was checked by the executor and is wrong: in the
  `for`, `stamp = …` binds rather than filters and `before_or_at?(nil, _)` is false, so nil stamps
  are reported as late — recorded so nobody chases it.
- **S-27 (read-back finding, D2, 2026-10-21)** (1) `SELECT current_database()` over the default psql connection on the Spark returns the OS-user database, which has no `kb_documents`; the populated application database is `kerf_prod` (the plan's S-14 text assumed the default connection was the app DB). Ruling needed: `--db` default `"kerf_prod"`, asserted in D2's test as the parse_args default (the string appears in lib and test once each — it is a database name, not a secret). (2) An `email_triage` table **exists** in `kerf_prod` (FK `document_id → kb_documents.id`), contradicting the private notes' "There is no `email_triage` table" and settling the note's open item in favour of `taxonomy.ex`. Not used by D2; the owner reconciles the private notes. Triage results in `kb_feedback` (feedback_type `triage`) are unaffected by this finding until someone reads both tables. **Owner 2026-10-21 06:57:** S-27 accepted; `--db` default `"kerf_prod"`; the owner corrects the private notes on `email_triage`.
- **S-28 (lead rulings on the six H3 pins requested by kerf-eval-harness 2026-10-21 before its RED; owner may veto before H3 GREEN)** (1) §2.3's "Enum.shuffle under :rand.seed" sentence was stale since S-22 — rewritten to the Fisher–Yates wording. (2) Isolation lines are emitted inside each selected item's block, after the separate probe, `isolation_sibling` before `isolation_state`; the selected items are the first `isolation_items` eval-split items by id among the items in scope; the RED asserts the position. (3) Scope under `--limit` is the first `limit` items in manifest order; `n_eval` counts the eval-split items in that scope and isolation items are chosen from that subset — exactly what S-25(3) makes `Score` expect; the RED cross-checks a limited run through `Score.coverage/2` (expected == answered). (4) `Kerf.Decide.Adapter` types `info/0` as a plain map and `Kerf.Decide.Adapter.HTTP.info/0` returns one (read-back 2026-10-21), so a struct can only come from a stub: `run/2` returns `{:error, {:invalid_header, _}}` with zero ask calls and never raises when `info/0` returns anything but a plain map. (5) `Kerf.Decide.ask/3` has no rescue around `adapter.ask/3` (`lib/kerf/decide.ex:169`), so the harness wraps every `Kerf.Decide.ask/3` call in `try … rescue … catch :exit`; an `{:error, reason}` return and a caught exception/exit are treated alike — one error line per question of that request with `result: null`, `error: inspect(reason)` — and the run completes (plan §4 item 5). The executor still quotes the live `ask/3` code in the RED commit. (6) `harness_seed` is per request (Random threads one state through all questions of a request), so the `question_index` slot is: packed main request → 6 with that request's `order_index`; separate request → the question's position in `Questions.order/0` (0..4), `order_index` 0; `isolation_sibling` → 5, `order_index` 0; `isolation_state` → 5, `order_index` 1. All < 64; the permutation seeds of `orders_for/5` (per question, 0..4) are untouched, and no two requests of one item share a tuple. `harness_gold` for the isolation probes carries `secret_present: false | true`. **Owner 2026-10-21 09:10:** S-28 accepted; GREEN H3 authorized on 78e5508.
- **S-29 (contract gap, D2 RED — kerf-eval-data 2026-10-21 07:00; lead ruling, owner may veto before D2 GREEN)** §6 D2 said `build_manifest/3` "seeds category … leaves other labels nil", but live `Manifest.validate/1` (`manifest.ex:293-296, 339-361`, verified by the lead) accepts `labels` only as nil or a full five-key map — a partial map fails with `:missing_question_label` — and `counts.labelled` counts any non-nil `labels`. A seeded category therefore had no legal home. Ruling: **option (A)** — `Item` gains `seed_category: String.t() | nil` (after `source_id`); `build_manifest/3` sets it from the override and `label_sources["category"] = "adjudicated"` at seeding, `labels` stay nil; `validate/1`, `put_label/4` and `counts` are untouched (the loader's `@item_fields` derives from the struct, so only `item.ex` changes for load/save). D4 pre-fills the category control from `seed_category`. Rejected: (B) partial label maps pre-freeze (muddies `counts.labelled` and `:frozen_incomplete`); (C) value only in `label_sources` (loses the value). RED asserts with `assert %{seed_category: _} = item` patterns. Open for the owner (not blocking): `put_label/4` keeps `"adjudicated"` whatever category the owner picks — if a label that differs from the seed should become `"new"`, that is a D1-level RED later. **Owner 2026-10-21 09:10:** option (A) accepted. Follow-up (D1-level RED, scheduled at D4 time, same executor): `put_label/4` with a `"category"` label that differs from `seed_category` sets `label_sources["category"] = "new"`; an equal label keeps `"adjudicated"`; a nil `seed_category` is `"new"` as today.
- **S-30 (two security pins proposed by kerf-eval-data at D2 RED cdfdb56, 2026-10-21 07:05; lead recommends both as one RED amendment before GREEN; owner decides)** (1) `--raw` writes the raw export rows — PII — yet §3 lists only `--out`/`--hashes-out`/`--report`/`--summary`/`--temperature-out`/`--out-dir` for the repo-root refusal; the omission is the plan's. Proposed: `--raw` joins the §3 list, RED asserts `parse_args` refuses a repo-root `--raw`. (2) `Export.ssh_command/3` interpolates `host` and `db` into a remote shell string; neither is validated. Proposed: `parse_args/1` rejects `--host`/`--db` values not matching `~r/\A[A-Za-z0-9][\w.-]*\z/` with `{:error, string}` (hard rule: input validation on user-facing functions; the leading alphanumeric is required because a value starting with `-`, e.g. `-oProxyCommand=…`, would be parsed by ssh as an option — commit-review nit on 373368c), RED asserts `--db "x; rm -rf"`, `--host "a b"` and `--host "-oProxyCommand=x"` are errors and the SQL never sees them. Both are test-file-only amendments on top of cdfdb56; the lead re-gates the amended sha and the GREEN authorization carries over. **Owner 2026-10-21 09:10:** both accepted, plus a third item: (3) `parse_args/1` rejects a malformed `--since` (e.g. `"yesterday"`, `"180"`, `"-5d"`) with `{:error, _}`, `"180d"` parses; `query/1`'s 180-day fallback stays as defence in depth. The amendment is test-file-only on top of cdfdb56, commit `test(RED): SPEC_H D2 — --raw refusal, --host/--db validation, malformed --since rejected (F08.1, S-30)`; the lead re-gates; GREEN D2 is authorized on the amended sha. Relayed 09:12.
- **S-31 (H3 RED 78e5508 executor choices where the plan was silent; lead accepts all five, owner may veto before H3 GREEN)** (a) `item_index` = 0-based position in `manifest.items`. (b) Isolation lines carry `order_index 0`, `packed false`, `order null`. (c) The sibling request = the probe (`Questions.secret_probe(token)`) plus at least one sibling question whose instructions contain the token, state content unchanged; the state request carries the token in the content and in no non-probe instructions; which sibling is used is not asserted. (d) State content matches `"From: <line containing the address>\nSubject: S\nDate: D\n\n<body>"`, display-name format free (§2.6). (e) `harness_gold` is the full 5-key map on main and separate requests (Oracle reads only the keys it is asked). Read-backs quoted in the RED commit: `decide.ex:35-39, 167-174` (no rescue around `adapter.ask/3`), `adapter.ex:14, 24` (info/0 a plain map), `http.ex:45`, `manifest.ex:112, 721-723`. Validation the executor reported: 30/30 against an uncommitted throwaway implementation, 30 single-pin mutations each caught. **Owner 2026-10-21 09:10:** S-31 accepted; GREEN H3 relayed 09:12 with one confirmation requested in the GREEN message: the line that withholds `harness_gold` from every non-Oracle adapter request.
- **S-32 (gate finding, D2 GREEN 53204ae, 2026-10-21 09:22; owner ruling needed before merge)** `mix dialyzer` reports 38 warnings against the 26 baseline. All 12 new ones sit in the two new task files `lib/mix/tasks/kerf.eval.export.ex` (7) and `lib/mix/tasks/kerf.eval.freeze.ex` (5) and are the known PLT artefact: `callback_info_missing (Mix.Task)` and `unknown_function` for `Mix.raise/1`, `Mix.shell/0`, `Mix.Task.run/1`, because `:mix` is not in the dialyzer PLT — identical in kind to the 5 on `kerf.eval.replay.ex` and the warnings on every other `lib/mix/tasks/*.ex` already in the baseline. The eval library modules (`lib/kerf/eval/**`) carry 0. The §3 rule "0 new warnings" was written for library modules; a new mix task cannot meet it under the current PLT. Options: (a) accept 38 as the new baseline (the H4 task file `kerf.eval.decide.ex` will add the same class again); (b) owner adds `:mix` to `plt_add_apps` in `mix.exs` (config change, owner-owned, separate commit) and the baseline drops for every task file. Lead recommendation: (b), done once after the D2 merge, with the plan's baseline number re-recorded; GREEN D2 itself is accepted as is. **Owner 2026-10-21 11:18: (b) done** — commit 1cd8c99 `plt_add_apps: [:mix, :ex_unit]`; baseline 4 (pattern_match_cov catch-alls: `system_page.ex:90`, `ollama_provider.ex:163`, `provider.ex:175`, `vllm_provider.ex:330`); rule from here: 0 new over 4, mix task files included (§3 updated).
- **S-33 (lead design ruling for the owner's S-30 follow-up, 2026-10-21 09:26; owner may veto before the new GREEN)** The owner asked for a test of "the export mix task's core (`Kerf.Eval.Export.run/2` or equivalent)" with a recording runner and the three bad `--host`/`--db` values. At 53204ae no such function exists: the mix task's `run/1` performs parse → fetch → select → build → save itself. Ruling: the RED introduces `Export.run(argv, opts) :: {:ok, %{manifest_path, rows}} | {:error, term}` taking **raw argv** (a parsed config could never carry a bad value, so the test would be vacuous) with two injection seams, `opts[:runner]` (existing, `System.cmd/2` default) and `opts[:query_fn]` (default `&query/1`, added so the test can count `query/1` calls without tracing); the mix task's `run/1` shrinks to Mix boilerplate plus `Export.run(argv, [])`. The RED asserts for each bad value `{:error, _}` with both counts 0, plus a positive control (benign argv, tmp `--out`, runner stub returning two rows → `{:ok, _}`, each seam invoked exactly once, manifest written and loadable) so the zero counts cannot pass on a no-op. `ssh_command/3` keeps its list return on success and returns `{:error, _}` for a host or db outside `~r/\A[A-Za-z0-9][\w.-]*\z/` (owner addition); the RED asserts the two refusals. Chain mechanics: `eval/data` is unpushed, so the executor resets it to 13be0b9, commits RED amendment #2, the lead re-gates, then the executor cherry-picks the kept GREEN, adds `run/2` and the `ssh_command/3` guard, and squashes into one GREEN commit.
- **S-34 (lead reading of §2.7 at H4 dispatch, 2026-10-21 11:26; owner may veto before H4 GREEN)** §2.7 lists `[--base-url URL] [--allow-remote]` without saying what `--allow-remote` gates. Reading: a `--base-url` whose host is not loopback (`127.0.0.1`, `localhost`, `::1`) is `{:error, msg}` unless `--allow-remote` is given (the harness otherwise sends mail content to a non-local endpoint by default); `--base-url` and `--timeout` are passed to the HTTP adapter as `adapter_opts` (`base_url:`, `timeout:`) and are rejected for `random`/`oracle`, which take no options. The executor pins this in the H4 RED or writes its own reading here.
  **Executor's pins in RED 5c0531f (kerf-eval-harness 11:32; owner veto open before GREEN):** (a) a testable core `CLI.run(argv) :: {:ok, map} | {:error, term}` takes raw argv and does the work (S-33 precedent); the mix task is `app.config` + `CLI.run/1` + print/`Mix.raise`; `score` returns `%{report_sha256: hex}` and the task prints it. (b) **Deviation from the lead's reading:** the host check mirrors the HTTP adapter's own policy (`lib/kerf/decide/adapter/http.ex:85-93`: `"localhost"` exactly, parsed IPs `{127,_,_,_}`, `{100,64..127,_,_}` tailnet CGNAT, `::1`), exact match via `parse_address` on the parsed host — `localhost.evil.example`, `127.0.0.1.example.invalid`, `10.0.0.5`, `100.128.0.1` refused; `127.0.0.1`, `localhost`, `[::1]`, `100.100.1.2` accepted without `--allow-remote`. Rationale: a loopback-only CLI would force `--allow-remote` for a Mac→Spark run over the tailnet, which disables the adapter's own guard for the whole run; mirroring keeps one policy. Strict loopback-only is a one-test change. `--allow-remote` → `adapter_opts allow_remote: true`; `--base-url` must be http(s) with a host; `--timeout` positive integer → `timeout:`; http without `--base-url` adds none (adapter config applies); random/oracle refuse `--base-url`, `--timeout`, `--allow-remote`; a custom `Elixir.*` adapter receives base_url/timeout; an existing non-adapter module (`Elixir.Enum`) and an unknown `Elixir.*` name are errors, no atom created. (c) Pin 3 shapes: `{:error, {:manifest_sha256, _}}` for nil/absent `manifest_path`; `{:error, {:missing_option, :adapter | :seed}}`. (d) Selftest summary `%{manifest, runs: %{random | oracle_1 | oracle_2 => %{gates, report_sha256, files}}, random_raw_ece: %{q => float}, random_scaled_f09_2, oracle_normalized_identical, oracle_reports_identical}`; artefacts `<run>.jsonl`, `.norm.jsonl`, `.report.json`, `.report.md` ×3 plus `temperatures.json` keyed by run name; `opts[:manifest]` used in place, default writes `out_dir/manifest.json`; all runs seed `opts[:seed] || 1`; unready/missing manifest → `{:error, [_ | _]}`; `--manifest synthetic` == default pinned, the 220+24 default branch has no test of its own. (e) Observation for the owner (Decide read-only): `Kerf.Decide.Adapter.HTTP.info/0` (http.ex:45-52) builds `model_id` from app config only, so a CLI run with `--base-url` records `"http:unconfigured"` in the header and histograms unless config is set — step-1 follow-up candidate. Lead view: (a), (c), (d) are the natural readings; (b) is a real policy choice the owner should rule — the lead leans to the executor's mirror (one policy, tailnet is the actual Mac→Spark path, exact match kept) while noting the strict list is the smaller attack surface.
  **Owner 2026-10-21 11:48:** S-34 = adapter mirror — loopback and tailnet accepted without the flag, every other host refused unless `--allow-remote`, the `--base-url` host compared exactly (the adapter's option is the boolean `allow_remote:`, http.ex:36; the CLI forwards only `allow_remote: true`). No amendment; GREEN H4 on 5c0531f.
- **S-35 (owner 2026-10-22 09:44, task H4b; lead notes at dispatch, owner may veto before H4b GREEN)** Owner items: (a) `run` refuses an existing `--out` unless `--force` (same rule as export); (b) the sink checks `IO.binwrite/2`'s return, a write error aborts the run with `{:error, {:write_failed, path, reason}}` and no `run_end` is written; (c) an `Application.ensure_all_started(:req)` failure goes through `Mix.raise` with the reason, covered by a test with an injected starter; (d) the hashes file is written `0o600`. Symlink resolution in `inside?/2` stays on the later-RED list. Lead notes: (1) **(d) is reassigned to D4.** The hashes file is written by `Kerf.Eval.Manifest.PII.write_hashes/2` (`pii.ex:54-66`), inside kerf-eval-data's owner block; the harness executor may not touch it, so the test (`pii_guard_test.exs`) and the `File.chmod(tmp, 0o600)` before the rename ride in D4's RED and GREEN (same executor, same commits). Alternative if the owner prefers a separate commit pair: a D3b on `eval/data` before D4. (2) Export has no `--force`: `export.ex:351` refuses an existing `--out` outright with `"<path> exists; refusing to overwrite it"`; "same rule" is read as that refusal and message, with `--force` new to `mix kerf.eval.decide run` only — the export task gains no `--force` unless the owner asks. (3) The sink contract change (`:ok | {:error, term}`, checked by the harness) stays inside the harness owner block; the only existing sink test (`harness_test.exs:725-728`) already returns `:ok`, so no committed test changes. (4) `--raw`'s `chmod 600` (D2 later-RED candidate, `export.ex:368-370` writes with default mode) is not part of (d); listed for the owner next to it. (5) **Plan correction (RED H4b 2d9f1f2 finding by kerf-eval-harness, confirmed by the lead on Elixir 1.20.1 `lib/io.ex:306-310`):** `IO.binwrite/2` is `@spec … :: :ok` and raises `ErlangError` on a write error (a `[:read]` device raises `:ebadf`); it never returns `{:error, reason}`, so §7 H4b (b) as first written was wrong — and live `CLI.run/1` (92b6e07) raises out on a write error, leaving a partial run file without `run_end` behind (the defect H4b closes). Lead ruling, owner may veto before GREEN: option (i) — `file_sink/2` calls `:file.write/2` directly and maps `{:error, reason}`; no rescue, no exception-driven control flow (option (ii), `rescue ErlangError`, rejected). The RED pins only `file_sink/2`'s result, so nothing in the RED changes; §7 H4b (b) corrected. `config.force` accepted as the parsed key name.
