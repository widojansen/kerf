# Addendum Spec — Switch vLLM Structured Output from `guided_json` to `response_format`

## Status

- **Type:** Bug fix (addendum to `structured_output_provider_detection_fix.md`)
- **Component:** `Kerf.StructuredOutput`
- **Workflow:** TDD (Red → Green → Refactor)
- **Estimated scope:** 1 function modified, 2 existing tests updated, 0 new files
- **Deploy impact:** Mix release rebuild + symlink swap; no migrations; no env changes
- **Prerequisites:** The previous spec (`detect_provider/1` fix) has already been merged. vLLM has already been reconfigured with `--reasoning-parser step3` (deployed 2026-05-10).

## Context

The previous spec corrected `detect_provider/1` so Nemotron and Ollama models route through the `:vllm` and `:ollama` provider builders. After deploying that change, however, the bug is only half-fixed because:

**vLLM 0.15.1 silently ignores the `guided_json` request parameter.** Verified directly against the production vLLM on the Spark on 2026-05-10:

```
WARNING [protocol.py:53] The following fields were present in the request but ignored: {'guided_json'}
WARNING [protocol.py:53] The following fields were present in the request but ignored: {'extra_body'}
```

`guided_json` was removed from the OpenAI-compatible chat-completions schema in vLLM ≥0.10. The replacement parameter is `response_format` with `type: "json_schema"`, which IS honored by 0.15.1.

Verified working against live vLLM with the actual production schema (`email_classification`):

```json
{
  "category": "spam",
  "priority": 2,
  "action": "ignore",
  "confidence": 0.85,
  "summary": "..."
}
```

Schema-conformant output, enum values from the actual enum (`"spam"`, not `"Promotional"`), priority within bounds, reasoning cleanly separated to `reasoning_content` (now that `--reasoning-parser step3` is configured).

## Root cause restated

`Kerf.StructuredOutput.build_provider_opts/5` for `:vllm` currently emits:

```elixir
[
  system: system,
  temperature: temperature,
  max_tokens: max_tokens,
  guided_json: schema_def.json_schema   # vLLM 0.15.1 ignores this
]
```

`Kerf.LLM.VLLMProvider` already plumbs `response_format` into the request body (line 132 of `vllm_provider.ex`, no changes needed there). The fix is to change what `StructuredOutput` emits.

## What "fixed" looks like

After the fix:

1. `build_provider_opts(schema_def, :vllm, ...)` emits `response_format:` instead of `guided_json:`
2. The `response_format` value is the OpenAI/vLLM-compatible shape: `%{"type" => "json_schema", "json_schema" => %{"name" => "...", "schema" => schema_def.json_schema}}`
3. The two existing tests that assert/refute `guided_json` are updated to assert/refute `response_format`
4. End-to-end: when `EmailTriage.Classifier` falls through to the LLM, the model produces enum-valid JSON in `content` and reasoning prose in `reasoning_content`. The classifier's existing JSON parser handles `content` as before.

Strict mode (`strict: true`) is **not enabled** in this spec because the `email_classification` schema has an optional `confidence` field that's not in `required` — strict mode requires all properties to be in `required`. Live testing confirmed non-strict mode works correctly. Tightening to strict mode is a future enhancement, not part of this fix.

## TDD sequence

### Step 1 — RED: update the existing tests

In `test/structured_output/structured_output_test.exs`, locate the `describe "complete/4 — provider detection"` block (around line 273) and update the two existing tests:

**Test 1 — "passes guided_json for vLLM-style models" (rename and update assertions)**

Rename the test to `"passes response_format with json_schema for vLLM-style models"` and replace the assertion. The new assertions should be:

```elixir
opts = Agent.get(call_opts, & &1)

# vLLM 0.15.1 ignores guided_json; response_format is the supported parameter.
refute Keyword.has_key?(opts, :guided_json)

response_format = opts[:response_format]
assert response_format != nil
assert response_format["type"] == "json_schema"
assert is_map(response_format["json_schema"])
assert is_binary(response_format["json_schema"]["name"])
assert is_map(response_format["json_schema"]["schema"])
```

**Test 2 — "augments system prompt for non-vLLM providers" (extend the refute clause)**

The test already does `refute Keyword.has_key?(opts, :guided_json)`. Add one line so it also refutes `:response_format`:

```elixir
refute Keyword.has_key?(opts, :guided_json)
refute Keyword.has_key?(opts, :response_format)
```

Run: `mix test test/structured_output/structured_output_test.exs`
Expected: the renamed test fails (the code still emits `guided_json`, not `response_format`). Test 2 also fails if anything in the codebase erroneously sets `:response_format` for the anthropic path — should pass cleanly. **Confirm RED before continuing.**

### Step 2 — GREEN: minimal implementation

In `lib/kerf/structured_output/structured_output.ex`, replace the body of `build_provider_opts(_, :vllm, ...)`. Currently:

```elixir
defp build_provider_opts(schema_def, :vllm, opts, temperature, max_tokens) do
  system = build_system_prompt(schema_def, Keyword.get(opts, :system))
  [
    system: system,
    temperature: temperature,
    max_tokens: max_tokens,
    guided_json: schema_def.json_schema
  ]
end
```

Replace with:

```elixir
defp build_provider_opts(schema_def, :vllm, opts, temperature, max_tokens) do
  system = build_system_prompt(schema_def, Keyword.get(opts, :system))
  schema_name = Keyword.get(opts, :schema_name, "Response")

  response_format = %{
    "type" => "json_schema",
    "json_schema" => %{
      "name" => to_string(schema_name),
      "schema" => schema_def.json_schema
    }
  }

  [
    system: system,
    temperature: temperature,
    max_tokens: max_tokens,
    response_format: response_format
  ]
end
```

Notes for the implementer:

- **String keys, not atom keys.** `Jason.encode!/1` happily encodes both, but vLLM expects standard JSON object property names. Using string keys here makes the wire shape obvious to anyone reading the code.
- **`schema_name` defaulting to `"Response"`.** vLLM's `json_schema.name` field is required. Most callers won't supply one. If `complete/4` is called with `schema_name: :email_classification` (atom or string) we coerce via `to_string/1`. Look in `complete/4` for whether the schema's registered name is already in `opts` — if so, prefer that as the default.
- **No `additionalProperties: false`, no strict mode.** Existing schemas have optional fields and use additional properties freely. Live testing confirms non-strict mode works on this vLLM. A future spec can tighten this.

If `complete/4` already has the schema's registered atom name in scope, thread it through to `build_provider_opts` so the default is more informative than `"Response"`. Look near the top of `complete/4`:

```elixir
def complete(schema_name, model, messages, opts \\ []) do
  # ...
  with {:ok, schema_def} <- get_schema(schema_name, registry) do
    provider_type = Keyword.get(opts, :provider_type, detect_provider(model))
    base_opts =
      build_provider_opts(schema_def, provider_type, opts, temperature, max_tokens)
    # ...
  end
end
```

Pass `schema_name` into `build_provider_opts` (add it to the function signature, or thread via `opts`). Either form is fine; my preference is adding it to opts in `complete/4` before the call:

```elixir
opts_with_name = Keyword.put_new(opts, :schema_name, schema_name)
base_opts = build_provider_opts(schema_def, provider_type, opts_with_name, temperature, max_tokens)
```

That way no signature changes propagate.

Run: `mix test test/structured_output/structured_output_test.exs`
Expected: both updated tests pass. **Confirm GREEN before continuing.**

### Step 3 — REFACTOR

Run the full suite:

```
mix test
```

Watch for:

- **Other tests that mock or stub the `:vllm` provider opts shape.** Anything that asserts `opts[:guided_json]` somewhere we didn't update needs the same refactor. `grep -rn 'guided_json' test/` should surface them.
- **The `add_if_present` mechanism in `VLLMProvider`** still handles `:guided_json` for backward compatibility. Don't remove that — it's harmless dead code on this vLLM and may matter for future callers or older deployments. (No change needed in `vllm_provider.ex`.)

If a test was previously asserting `guided_json` for a vLLM model, that test was encoding the now-known-broken assumption — update the expectation.

Optional cleanup (don't do in this PR, just note): the comment in `vllm_provider.ex` line 128 says `# Structured output: pass through guided decoding params to vLLM.` That's still true but stale-feeling. A docstring update could be a follow-up.

### Step 4 — Manual verification on the Spark (before deploy)

Build the release locally, then verify against live vLLM with `bin/kerf rpc` on the Spark:

```bash
cd ~/Projects/kerf/kerf
MIX_ENV=prod mix release --overwrite
```

Then SSH to the Spark and use the existing release (or scp the new tarball, but easier: just call vLLM directly first to prove the wire shape):

```bash
ssh spark
# Prove vLLM accepts the exact response_format shape Kerf will send:
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nemotron-cascade-2",
    "messages": [{"role": "user", "content": "From: shop@example.com Subject: 30 percent off Body: discount. Classify."}],
    "max_tokens": 400,
    "temperature": 0.0,
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "EmailClassification",
        "schema": {
          "type": "object",
          "properties": {
            "category": {"type": "string", "enum": ["business", "personal", "newsletter", "transactional", "spam"]},
            "priority": {"type": "integer", "minimum": 1, "maximum": 5},
            "action": {"type": "string", "enum": ["follow_up", "archive", "flag", "ignore"]},
            "confidence": {"type": "number", "minimum": 0.0, "maximum": 1.0},
            "summary": {"type": "string", "maxLength": 500}
          },
          "required": ["category", "priority", "action", "summary"]
        }
      }
    }
  }' | python3 -m json.tool
```

Expected: `content` is pure JSON matching the schema, `reasoning_content` is populated with the reasoning chain, `category` is one of the enum values (typically `"spam"` for this prompt).

This was already verified manually on 2026-05-10 — re-running it before deploy is a sanity check that nothing regressed.

## Deploy

Standard release deploy from the Mac:

```bash
cd ~/Projects/kerf/kerf
./deploy/deploy.sh
```

Then watch for the first few LLM-path classifications:

```bash
ssh spark
journalctl -u kerf.service -f | grep -i 'EmailTriage\|Classification\|validation_failed'
```

Within ~10 minutes the EmailIngestor will have polled at least one cycle. Look for absence of `validation_failed` errors on the LLM path. There may still be `connection_refused` if vLLM has a hiccup, but those are unrelated to this fix.

## Verification queries (run 24h after deploy)

```sql
-- From the Mac:
ssh spark 'export PATH=$HOME/.asdf/shims:$PATH && psql kerf_prod -c "
SELECT
  DATE(inserted_at) AS day,
  COUNT(*) FILTER (WHERE decision = '\''unclassified'\'') AS llm_failed,
  COUNT(*) FILTER (WHERE context->>'\''source'\'' = '\''llm'\'') AS llm_succeeded,
  COUNT(*) FILTER (WHERE context->>'\''source'\'' = '\''fast_classifier'\'') AS fast_classified,
  ROUND(100.0 * COUNT(*) FILTER (WHERE decision = '\''unclassified'\'') / NULLIF(COUNT(*) FILTER (WHERE decision = '\''unclassified'\'' OR context->>'\''source'\'' = '\''llm'\''), 0), 1) AS llm_failure_pct
FROM kb_feedback
WHERE feedback_type = '\''triage'\'' AND inserted_at > NOW() - INTERVAL '\''3 days'\''
GROUP BY 1 ORDER BY 1;
"'
```

**Baseline (pre-fix, week of May 4):** 44 failed / 292 succeeded = 13.1% LLM failure rate.

**Expected post-fix:** LLM failure rate drops below 5% within 24 hours, ideally below 2%. The remaining failures should be transient infrastructure errors (vLLM down, OAuth refresh blip), not schema or parsing failures.

If failure rate does NOT drop substantially:
- Check vLLM logs for the "ignored fields" warning — if it appears with `response_format`, vLLM is rejecting the shape and we have a different bug
- Check that `--reasoning-parser step3` is still configured (`grep reasoning-parser /etc/systemd/system/vllm.service`)
- Spot-check a few `kb_feedback` rows with `decision = 'unclassified'` and look at the `context->>'error'` to see what error class predominates

## Out of scope

- **Strict mode (`strict: true`):** Requires schemas to add `additionalProperties: false` and put all properties in `required`. The `email_classification` schema's optional `confidence` field would need to move into `required` or be dropped. Worth doing as a future hardening pass, not part of this fix.
- **Removing the dormant `guided_json` plumbing in `VLLMProvider`:** Harmless on this vLLM, may matter for future deployments. Keep it.
- **Tina chat agent:** The `</think>` leak was the same root cause as this bug. With `--reasoning-parser step3` already deployed (2026-05-10), Tina's `content` should now be clean. Verify in a separate session that Tina's agent code reads `message.content` (not the raw response shape).
- **Logging visibility on the EmailTriage path:** Triage activity isn't logged at info level. Add structured logs in a follow-up.

## Why this is the right fix to ship next

- **Precondition is already satisfied.** vLLM is configured with `step3`, the previous `detect_provider/1` fix is merged, this is the last piece.
- **Smallest diff.** One function body, two test bodies. ~20 LOC total change.
- **Verified shape.** I have already exercised the exact `response_format` wire shape against live production vLLM and confirmed it produces correct, schema-valid output.
- **Reversible.** If something misbehaves, revert is one symlink swap to the previous release.
- **High leverage.** Combined with the already-deployed `step3` switch, this should drop LLM-path failures from ~13% to <2%.
