# Spec — Fix `StructuredOutput.detect_provider/1` for Nemotron and Ollama models

## Status

- **Type:** Bug fix
- **Component:** `Kerf.StructuredOutput`
- **Workflow:** TDD (Red → Prompt → Green → Refactor)
- **Estimated scope:** 1 function, ~12 LOC, 1 test file with ~6 cases
- **Deploy impact:** Mix release rebuild + symlink swap; no migrations; no env changes

## Context

Phase B email triage on Kerf is running in production with healthy throughput (~235 emails/day, 13-day uptime). The pipeline shipped with FastClassifier, which deterministically classifies ~85% of emails in milliseconds. The remaining ~15% goes to an LLM via `Kerf.StructuredOutput.complete/4`, which currently calls `nemotron-cascade-2` on the local vLLM instance.

Of those ~15% LLM calls, ~13% fail with `validation_failed`. Database evidence (collected 2026-05-10):

| Failure category | Count | Share |
|---|---|---|
| "no valid JSON found in content" | 220 | ~41% |
| Schema enum mismatches (e.g. category "Promotional", action "Read and archive") | ~50 | ~10% |
| "API key not configured" | 39 | ~7% |
| "connection refused" (vLLM down) | 9 | ~2% |
| Type-coercion failures (int where string expected) | 6 | ~1% |
| Other (long-tail variations of enum mismatch) | ~210 | rest |

The schema-enum and JSON-parse failures share a single root cause: **vLLM's `guided_json` parameter is never being sent**, so the model output is unconstrained. It returns sensible-but-out-of-enum values like `"Promotional"` instead of `"newsletter"`, or emits reasoning prose alongside the JSON.

## Root cause

`Kerf.StructuredOutput.detect_provider/1` (in `lib/kerf/structured_output/structured_output.ex`) uses string-prefix heuristics to choose between `:vllm`, `:anthropic`, and `:ollama` provider option-builders:

```elixir
defp detect_provider(model) do
  cond do
    String.starts_with?(model, "claude") -> :anthropic
    String.starts_with?(model, "nvidia/") -> :vllm
    String.contains?(model, "/")          -> :vllm
    true                                  -> :anthropic
  end
end
```

The currently-deployed Kerf models are:

- `nemotron-cascade-2` — served by vLLM, used by `EmailTriage.Classifier`
- `qwen3:8b` — served by Ollama, default for some sessions
- `claude-*` — Anthropic, optional
- `bge-m3` — Ollama, embeddings only (different code path; not affected)

`nemotron-cascade-2` has no slash, so the cond falls through to `:anthropic`. `qwen3:8b` contains a colon, not a slash, so it also falls through to `:anthropic`. The result: `build_provider_opts/5` takes the non-vLLM branch, which puts the JSON schema in the *system prompt as instructions* rather than in vLLM's `guided_json` request parameter.

Without `guided_json`, vLLM does not constrain output to the schema's enum values. The model is asked nicely (in prose) to follow the schema but is free to paraphrase. Hence: `"Promotional"`, `"Read and archive"`, capitalized `"Newsletter"`, and verbose reasoning chains that occasionally truncate before emitting valid JSON.

The bug does **not** affect routing — `Kerf.LLM.ModelRouter` uses regex routes and dispatches correctly to `Kerf.LLM.VLLMProvider`. Only the StructuredOutput options-builder is affected.

## What "fixed" looks like

After the fix:

1. `detect_provider("nemotron-cascade-2")` returns `:vllm`
2. `detect_provider("qwen3:8b")` returns `:ollama`
3. `detect_provider("claude-sonnet-4-6")` still returns `:anthropic` (no regression)
4. `detect_provider("nvidia/Llama-3.1-Nemotron-70B-Instruct-HF")` still returns `:vllm`
5. Unknown models default to `:anthropic` (existing behaviour; safest fallback)
6. The `EmailTriage.Classifier` LLM path stops emitting out-of-enum values like `"Promotional"`
7. The 220+ "no valid JSON" failures shrink dramatically (predicted: <30/week from ~50/week)

## Detection strategy

Replace the prefix heuristic with **explicit pattern lists** plus a fallback. This is safer than ad-hoc string checks because it makes the model→provider map explicit and easy to extend as new models are added.

### Recommended structure

```elixir
defp detect_provider(model) do
  cond do
    anthropic_model?(model) -> :anthropic
    vllm_model?(model)      -> :vllm
    ollama_model?(model)    -> :ollama
    true                    -> :anthropic   # safe default
  end
end

defp anthropic_model?(model), do: String.starts_with?(model, "claude")

defp vllm_model?(model) do
  String.starts_with?(model, "nvidia/") or
    String.starts_with?(model, "nemotron") or
    String.contains?(model, "/")
end

defp ollama_model?(model) do
  # Ollama tag format: <name>:<tag>, e.g. "qwen3:8b", "llama3.2:latest"
  # Excludes Anthropic and vLLM patterns (already filtered above).
  String.contains?(model, ":") and not String.contains?(model, "/")
end
```

Notes:
- Anthropic check runs first because `claude-*` is unambiguous.
- The `nvidia/` and `*/*` checks for vLLM are **kept** for backward compatibility — anyone running an HF-style model name like `nvidia/Llama-3.1-Nemotron-70B` should continue to work.
- The `String.contains?(model, ":")` check for Ollama is the new branch. Ollama uses `name:tag` format consistently.
- Default fallback stays `:anthropic` because that builder works with any provider that serves `text` content (it injects schema-as-instructions into the system prompt). It is a degraded mode, not a broken one — that's why the system has been functional, just lossy.

## TDD sequence

### Step 1 — RED: write the failing test

Create `test/kerf/structured_output/structured_output_test.exs` (or add to an existing file if one exists for this module — check first with `find test -name '*structured_output*'`).

```elixir
defmodule Kerf.StructuredOutputTest do
  use ExUnit.Case, async: true

  describe "provider detection" do
    # detect_provider/1 is private — we test it indirectly via the public API
    # by checking which provider-opts shape is built. Alternatively, expose a
    # small public helper `which_provider/1` that wraps detect_provider.
    #
    # Recommended: add a public `which_provider/1` for testability and to give
    # the rest of the codebase a stable name to call.

    test "claude models resolve to :anthropic" do
      assert Kerf.StructuredOutput.which_provider("claude-sonnet-4-6") == :anthropic
      assert Kerf.StructuredOutput.which_provider("claude-3-5-haiku") == :anthropic
    end

    test "nemotron models resolve to :vllm" do
      assert Kerf.StructuredOutput.which_provider("nemotron-cascade-2") == :vllm
      assert Kerf.StructuredOutput.which_provider("nemotron-4-340b") == :vllm
    end

    test "huggingface-style names with slash resolve to :vllm" do
      assert Kerf.StructuredOutput.which_provider("nvidia/Llama-3.1-Nemotron-70B-Instruct-HF") == :vllm
      assert Kerf.StructuredOutput.which_provider("meta-llama/Meta-Llama-3-8B") == :vllm
    end

    test "ollama tag-format models resolve to :ollama" do
      assert Kerf.StructuredOutput.which_provider("qwen3:8b") == :ollama
      assert Kerf.StructuredOutput.which_provider("llama3.2:latest") == :ollama
      assert Kerf.StructuredOutput.which_provider("bge-m3:latest") == :ollama
    end

    test "unknown models default to :anthropic" do
      assert Kerf.StructuredOutput.which_provider("some-random-model") == :anthropic
      assert Kerf.StructuredOutput.which_provider("") == :anthropic
    end
  end
end
```

Run: `mix test test/kerf/structured_output/structured_output_test.exs`
Expected: compilation error (function `which_provider/1` undefined) or all tests fail. **Confirm RED before continuing.**

### Step 2 — GREEN: minimal implementation

In `lib/kerf/structured_output/structured_output.ex`:

1. Add the public helper just above `detect_provider/1`:

```elixir
@doc """
Returns the provider type for the given model name.
Public wrapper around the internal detection logic, exposed
for testing and for callers that need to branch on provider.
"""
@spec which_provider(String.t()) :: :anthropic | :vllm | :ollama
def which_provider(model), do: detect_provider(model)
```

2. Replace the body of `detect_provider/1`:

```elixir
defp detect_provider(model) do
  cond do
    anthropic_model?(model) -> :anthropic
    vllm_model?(model)      -> :vllm
    ollama_model?(model)    -> :ollama
    true                    -> :anthropic
  end
end

defp anthropic_model?(model), do: String.starts_with?(model, "claude")

defp vllm_model?(model) do
  String.starts_with?(model, "nvidia/") or
    String.starts_with?(model, "nemotron") or
    String.contains?(model, "/")
end

defp ollama_model?(model) do
  String.contains?(model, ":") and not String.contains?(model, "/")
end
```

3. Add an Ollama branch to `build_provider_opts/5` if one does not already exist. Currently the function has two heads:
   - `build_provider_opts(_, :vllm, _, _, _)` — uses `guided_json`
   - `build_provider_opts(_, _, _, _, _)` — fallback that injects schema as instructions

   For now, route `:ollama` to the same fallback (Ollama's structured output support varies by model and is best emulated via prompt). Confirm by checking whether `Kerf.LLM.OllamaProvider` accepts a `format: "json"` parameter — if it does, add a third head:

```elixir
defp build_provider_opts(schema_def, :ollama, opts, temperature, max_tokens) do
  user_system = Keyword.get(opts, :system, "")
  json_instructions = json_schema_instructions(schema_def)
  system = String.trim("#{user_system}\n\n#{json_instructions}")
  [
    system: system,
    temperature: temperature,
    max_tokens: max_tokens,
    format: "json"   # only if OllamaProvider supports it; otherwise omit this head
  ]
end
```

If `OllamaProvider` does not currently support `format: "json"`, **leave Ollama on the existing fallback** — the test still passes (provider type is correctly `:ollama`), and Ollama JSON-mode support can be a follow-up.

Run: `mix test test/kerf/structured_output/structured_output_test.exs`
Expected: all five test cases pass. **Confirm GREEN before continuing.**

### Step 3 — REFACTOR

Run the full test suite to make sure nothing else broke:

```
mix test
```

Pay attention to any tests that mock or stub `detect_provider/1` directly — they may need updating. Tests that exercise `Kerf.StructuredOutput.complete/4` for Nemotron should now exercise the `:vllm` branch of `build_provider_opts/5` and may surface a previously-hidden behaviour. Read failures before "fixing" them; the new behaviour is the desired one.

If a test was previously asserting `provider_type: :anthropic` for a Nemotron model, that test was encoding the bug — update its expectation to `:vllm`.

### Step 4 — Verify against vLLM directly

Before deploying, do a manual verification on the Spark by calling vLLM with `guided_json`. This confirms that vLLM accepts the schema and that the model returns valid output under it.

```bash
ssh spark
cd /opt/kerf/current
bin/kerf remote
```

In IEx:

```elixir
schema = Kerf.Agents.EmailTriage.Classifier.schema_definition()

opts = [
  guided_json: schema,
  temperature: 0.1,
  max_tokens: 512,
  system: "Respond with valid JSON matching the schema."
]

messages = [
  %{role: "user", content: """
  Classify this email.

  From: shop@example.com
  Subject: 30% off summer sale
  Body: Hi! Big discount this week.
  """}
]

Kerf.LLM.VLLMProvider.complete(Kerf.LLM.VLLMProvider, "nemotron-cascade-2", messages, opts)
```

Expected: `{:ok, %{type: :text, content: "{\"category\":\"newsletter\", ...}"}}` — pure JSON, no reasoning prose, no enum violations.

If vLLM rejects the `guided_json` parameter format, that's a separate finding (the parameter shape needs adjusting) and should be raised as a follow-up. Not blocking the spec's main fix.

## Deploy

Standard release deploy:

```bash
cd ~/Projects/kerf/kerf
./deploy/deploy.sh
```

Watch:

```bash
ssh spark journalctl -u kerf.service -f
```

For ~5 minutes after restart, the EmailTriage GenServer will pick up new emails. Watch for any `validation_failed` errors. There may still be some — Anthropic/connection failures are unaffected by this fix — but the rate of "no valid JSON" and enum-mismatch errors should drop noticeably within the first few LLM-path classifications.

## Verification queries (run 24h after deploy)

To confirm the fix is working in production, re-run the failure-rate query 24 hours after deploy:

```sql
-- From the Mac:
ssh spark 'export PATH=$HOME/.asdf/shims:$PATH && psql kerf_prod -c "
SELECT
  DATE(inserted_at) AS day,
  COUNT(*) FILTER (WHERE decision = '\''unclassified'\'') AS llm_failed,
  COUNT(*) FILTER (WHERE context->>'\''source'\'' = '\''llm'\'') AS llm_succeeded,
  COUNT(*) FILTER (WHERE context->>'\''source'\'' = '\''fast_classifier'\'') AS fast_classified
FROM kb_feedback
WHERE feedback_type = '\''triage'\'' AND inserted_at > NOW() - INTERVAL '\''2 days'\''
GROUP BY 1 ORDER BY 1;
"'
```

Expected post-fix: the `llm_failed` column for the day after deploy should drop from the recent baseline (~5–10/day) toward 0–2/day. The remaining failures should be transient (vLLM down, API-key issues), not schema or parsing failures.

## Out of scope

These are real issues but separate from this fix:

- **Tina's Telegram output leaks `</think>` tags** (memory entry 17) — this is in a different code path (Tina's chat agent, not the EmailTriage classifier) and uses a different prompt. Fix in a separate session.
- **Telegram surfacing of priority-5 emails** — the original April complaint that "important emails aren't surfaced to Telegram" is unverified. Investigate separately.
- **Memory high-watermark flapping** every 5–15 min on Spark — tunable, low priority.
- **Priority-5 every-5-minute pattern from a single sender** — possibly a misconfigured override rule, not related to the LLM path.

## Why this is the right fix to ship first

- **Smallest blast radius:** one private function, one new public helper for testability, one new private branch in `build_provider_opts/5`.
- **Highest leverage:** the bug is the upstream cause of >50% of LLM-path failures.
- **Reversible:** if the change misbehaves, revert is one symlink swap to the previous release.
- **Testable in isolation:** the fix is pure-function logic. No infrastructure mocks needed for the unit tests; the integration check in Step 4 is a single IEx invocation.
- **No migrations, no env changes, no risk to data at rest.**
