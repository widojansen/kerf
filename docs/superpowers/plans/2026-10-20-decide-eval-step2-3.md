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
manifest unchanged; owner amendment to D1 RED, 2026-10-20, F08.4/F08.5).

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
  `order_index 0` is identity (manifest order); 1..5 are `Enum.shuffle` under
  `:rand.seed(:exsss, {seed, item_index * 64 + question_index, order_index})` — a 3-tuple;
  `:rand.seed/2` raises on a 4-tuple (A3.11; `question_index < 64` always).
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
  `lib/`, the runtime-compiled test Router warning in `test/`. `mix dialyzer`: 0 new warnings.
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

### D2 — Export (`Kerf.Eval.Export`, `mix kerf.eval.export`) and `mix kerf.eval.freeze`  (model: Sonnet)

**Closes:** F08.1 (export with real From/Subject/Date via `source_metadata`), F08.7 (seeding from overrides, `"adjudicated"`).
**Read-back first (executor, read-only ssh):** `SELECT current_database();` (or `\l`) to verify the database name — it becomes the default of `--db`; `\d kb_documents`; confirm `doc_id` in `~/eval/golden-overrides.jsonl` matches `kb_documents.id` (or `source_id`) with one `SELECT … WHERE id = ANY(…)`. If it matches neither, stop and write Status S-3. Quote all three results in the RED commit message.
**Files:** create `lib/kerf/eval/export.ex`, `lib/mix/tasks/kerf.eval.export.ex`, `lib/mix/tasks/kerf.eval.freeze.ex`.
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
**RED tests:** `test/eval/export_test.exs` — query contains `source_type = 'email'`, `raw_text IS NOT NULL`, the naive-UTC interval, `ORDER BY inserted_at DESC, id`, no `now()` without `at time zone`; the `OR id = ANY` clause sits inside parentheses that are themselves preceded by `AND` (assert with a regex like `~r/AND \(inserted_at >= .*? OR id = ANY\(.*?\)\)/s` and assert no `OR` appears outside parentheses); `ssh_command(host, db, sql)` has the asdf prefix and heredoc and uses exactly the `db` argument (`"-d other_db"` when passed `"other_db"` — no literal database name asserted); `parse_args` honours `--db` and defaults it to the read-back value; `fetch_rows` with an injected runner (non-zero exit → error); `parse_rows` tolerates a bad line; `select` includes all override ids and is deterministic; `build_manifest` validates, seeds category only where an override exists and marks it `"adjudicated"`, leaves other labels nil; freeze task argv parsing (`Kerf.Eval.Export.parse_args/1` style, never raises).
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
**RED tests:** `test/eval/harness/cli_test.exs` (every subcommand's required flags, bad adapter alias → error, `--limit` parsed; every output path flag that resolves inside `File.cwd!()` → `{:error, msg}` naming the flag, a `System.tmp_dir!()` path accepted — §3 repo-root refusal), `test/eval/harness/selftest_test.exs` (runs `Selftest.run/2` into a tmp dir on `Synthetic.build(n: 60, pairs: 6)` (66 items, 11 calibration); asserts the summary; asserts artefact files exist and the oracle report sha256s match) — this is the F09.9 self-test itself, run in CI.
**GREEN gate:** `mix test test/eval/harness/cli_test.exs test/eval/harness/selftest_test.exs --no-start` both seeds; full suite both seeds; then owner runs `mix kerf.eval.decide selftest --out-dir ~/Projects/kerf/private/eval/decide/selftest/` once and files the summary (step-3 entry gate: "F09.9 self-test passes before any real model is run").

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
- H-9 Run the self-test once on the M5 and file its summary in the private tree (step-3 entry gate).

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
| — | H1b | RED — pending, starts after H2 GREEN is gated | — | — | — |
| — | H1b | GREEN — pending | — | — | — |

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

