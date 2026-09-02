# Spec — Isolate per-document errors in email triage and log silent batch failures

## Status

- **Type:** Bug fix (reliability + visibility)
- **Components:** `Kerf.Agents.EmailTriage.EmailTriage`, `Kerf.Ingestors.Email.EmailIngestor`
- **Workflow:** TDD (Red → Green → Refactor)
- **Estimated scope:** 2 functions modified, 2 test files modified (~3-5 new test cases total)
- **Deploy impact:** Mix release rebuild + symlink swap; no migrations; no env changes
- **Prerequisites:** None. Phase B email triage is running in production.

## Context

Phase B email triage is healthy: ~235 emails/day, 93%+ classified. Over the 5 weeks since deploy, **12 emails** (~0.15%) made it into `kb_documents` but never produced a `kb_feedback` row, and were never labeled in Gmail. The pattern observed in production:

- 5 of the 12 missed docs are paired with another missed doc within seconds of each other
- They are not pathological — manually re-triaging the same doc IDs succeeds without changes
- The journal contains no exception traces around the time of the misses

This last point is the most important: **the failures are happening but they're invisible.**

## Root cause

Two interacting issues. Both must be fixed.

### Issue 1 — Batch-level error propagation in `EmailTriage`

`Kerf.Agents.EmailTriage.EmailTriage.handle_call({:triage, document_ids}, ...)` processes a batch:

```elixir
def handle_call({:triage, document_ids}, _from, state) do
  results =
    document_ids
    |> Enum.flat_map(fn doc_id -> triage_document(doc_id, state) end)
  # ...
end
```

`triage_document/2` performs many operations — sender lookup, embedding fetch, interest matching, FastClassifier, LLM fallback, transactional record writes, Gmail label-apply, feedback recording. Any of them can raise on a transient failure (database timeout, vLLM connection refused, Gmail API hiccup, malformed sender data, etc.).

`Enum.flat_map` propagates exceptions. If `triage_document` raises on the **third doc in a batch of four**, the call site receives the exception — the **first two docs that succeeded internally still get their side-effects applied** (Gmail labels, kb_feedback rows for those that completed before the crash), but the **fourth doc is silently skipped** and the entire `handle_call` return value is the exception.

### Issue 2 — Silent batch swallow in `EmailIngestor`

`Kerf.Ingestors.Email.EmailIngestor`'s post-fetch hook (lib line ~233):

```elixir
if doc_ids != [] and state.triage_fn do
  try do
    state.triage_fn.(Enum.reverse(doc_ids))
  rescue
    _ -> :ok
  end
end
```

When the `triage_fn` call raises (because Issue 1 propagated an exception out of `Enum.flat_map`), the bare `rescue _ -> :ok` catches it, discards the exception type and stacktrace, and continues. No log line. No record. The exception that explains the missed docs is gone.

This is defensive code with the wrong default: defensive against process death (good), defensive against observability (bad).

## What "fixed" looks like

After the fix:

1. **Per-doc isolation:** A doc that raises during `triage_document/2` is logged but does NOT affect the rest of the batch. The exception is captured in a Logger.warning with the doc id and stack trace. The function returns `[]` for that doc and `Enum.flat_map` proceeds.
2. **Batch-level visibility:** If `triage_fn` somehow still raises (e.g., process exit, not a `rescue`-able exception), `EmailIngestor` logs the failure via `Logger.error` with stack trace and the doc_ids that were in flight. The rescue still swallows so the EmailIngestor keeps running, but the failure is now visible.
3. **No new behavior** for the happy path. Working batches continue to work exactly as before.
4. **The 12 stranded docs** that surfaced this bug are out of scope for the code change — operational cleanup is separate.

## TDD sequence

### Step 1 — RED: write failing tests

**Test file 1: `test/agents/email_triage/email_triage_test.exs`** (check first whether this file exists; if so, add to it).

Two new test cases under a new `describe "batch isolation"` block:

```elixir
describe "batch isolation" do
  test "one document raising does not abort the rest of the batch", %{state: state} do
    # Setup: three docs, middle one will cause triage_document to raise.
    # The simplest way to inject failure deterministically is to make
    # the second doc's source_metadata pathological in a way that the
    # implementation of triage_document would raise on. Two approaches:
    # (a) Use a real doc fixture with malformed metadata that crashes a downstream call
    # (b) Pass a non-existent doc id sandwiched between valid ones and mock
    #     repo.get/2 to raise on it specifically.
    # Recommend (b) because it's hermetic.

    valid_doc_a = insert_email_doc(%{subject: "first"})
    valid_doc_c = insert_email_doc(%{subject: "third"})
    pathological_id = "non-existent-uuid-that-will-raise"

    # Replace state.repo with a mock that raises on the pathological id only.
    repo_mock = make_raising_repo(state.repo, pathological_id)
    state_with_mock = %{state | repo: repo_mock}

    result =
      GenServer.call(
        start_test_triage(state_with_mock),
        {:triage, [valid_doc_a.id, pathological_id, valid_doc_c.id]}
      )

    # Expect: both valid docs get triaged (have feedback rows),
    # pathological one logged but not in result.
    assert match?({:ok, [%{document_id: id_a}, %{document_id: id_c}]} 
                  when id_a == valid_doc_a.id and id_c == valid_doc_c.id, result)
    
    # And kb_feedback rows exist for the two valid docs
    assert Kerf.Repo.exists?(
      from f in Kerf.Memory.Feedback,
      where: f.document_id == ^valid_doc_a.id and f.feedback_type == "triage"
    )
    assert Kerf.Repo.exists?(
      from f in Kerf.Memory.Feedback,
      where: f.document_id == ^valid_doc_c.id and f.feedback_type == "triage"
    )
  end

  test "raising in triage_document is logged with doc id and stacktrace" do
    # Capture log output during a triage that intentionally raises.
    pathological_id = "non-existent-uuid-that-will-raise"
    state_with_mock = build_state_with_raising_repo(pathological_id)

    log_output =
      capture_log(fn ->
        GenServer.call(
          start_test_triage(state_with_mock),
          {:triage, [pathological_id]}
        )
      end)

    assert log_output =~ "triage_document failed"
    assert log_output =~ pathological_id
    assert log_output =~ "stacktrace"  # or some stacktrace marker
  end
end
```

Run: `mix test test/agents/email_triage/email_triage_test.exs`
Expected: both new tests fail. The first fails because `Enum.flat_map` propagates the exception (the GenServer.call returns `{:error, ...}` or the test process receives an `EXIT`). The second fails because no logging exists yet. **Confirm RED before continuing.**

**Test file 2: `test/ingestors/email/email_ingestor_test.exs`**

One new test case:

```elixir
describe "triage_fn failure visibility" do
  test "exception in triage_fn is logged with stacktrace, EmailIngestor keeps running" do
    parent = self()

    triage_fn_that_raises = fn doc_ids ->
      send(parent, {:triage_attempted, doc_ids})
      raise "simulated triage failure"
    end

    {:ok, ingestor} = start_ingestor(triage_fn: triage_fn_that_raises, gmail_client: stub_returning_one_email())

    log_output =
      capture_log(fn ->
        GenServer.call(ingestor, :sync_now)
      end)

    # The triage_fn was called
    assert_receive {:triage_attempted, _doc_ids}

    # The exception was logged
    assert log_output =~ "triage_fn failed"
    assert log_output =~ "simulated triage failure"

    # The EmailIngestor is still alive (rescue continued)
    assert Process.alive?(ingestor)
  end
end
```

Run: `mix test test/ingestors/email/email_ingestor_test.exs`
Expected: the assertion `log_output =~ "triage_fn failed"` fails because the current `rescue _ -> :ok` logs nothing. **Confirm RED before continuing.**

### Step 2 — GREEN: minimal implementation

**Patch A:** In `lib/kerf/agents/email_triage/email_triage.ex`, modify the `handle_call({:triage, ...})` clause to isolate per-doc errors:

```elixir
def handle_call({:triage, document_ids}, _from, state) do
  results =
    document_ids
    |> Enum.flat_map(fn doc_id ->
      try do
        triage_document(doc_id, state)
      rescue
        e ->
          Logger.warning(
            "[EmailTriage] triage_document failed for #{doc_id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
          []
      catch
        kind, value ->
          Logger.warning(
            "[EmailTriage] triage_document caught #{kind} for #{doc_id}: " <>
              inspect(value, limit: 200)
          )
          []
      end
    end)

  new_state = %{state | documents_triaged: state.documents_triaged + length(results)}
  {:reply, {:ok, results}, new_state}
end
```

Two notes:

- Use `Logger.warning` (not `error`) because the system continues to function — a failed doc is recoverable via manual re-triage, not a system-level fault.
- Catch both `rescue e` (raised exceptions) AND `catch kind, value` (throws, exits). The latter handles cases like `GenServer.call` timeouts on downstream services, which raise `:exit` not exceptions.
- Add `require Logger` at the top of the module if not already present.

**Patch B:** In `lib/kerf/ingestors/email/email_ingestor.ex`, replace the silent rescue:

```elixir
if doc_ids != [] and state.triage_fn do
  try do
    state.triage_fn.(Enum.reverse(doc_ids))
  rescue
    e ->
      Logger.error(
        "[EmailIngestor] triage_fn failed for #{length(doc_ids)} doc(s): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
      :ok
  catch
    kind, value ->
      Logger.error(
        "[EmailIngestor] triage_fn caught #{kind} for #{length(doc_ids)} doc(s): " <>
          inspect(value, limit: 200)
      )
      :ok
  end
end
```

`Logger.error` here (not `warning`) because if Patch A is doing its job, the only way this layer triggers is something more serious than a single-doc problem — e.g., the EmailTriage process died, the schema changed under us, the entire batch was rejected at a layer below `triage_document`. Genuinely error-level.

Run: `mix test test/agents/email_triage/email_triage_test.exs test/ingestors/email/email_ingestor_test.exs`
Expected: all three new tests pass. **Confirm GREEN before continuing.**

### Step 3 — REFACTOR

Run the full suite:

```
mix test
```

Watch for:

- **Existing tests that exercise batch behavior** — they may have been silently relying on the exception-propagation behavior. Read carefully before "fixing"; the new behavior is the correct one.
- **Existing log-capture tests** that asserted "no logs" or "only INFO logs" — they may need updates if they exercised the now-logged paths.

If a test was previously asserting that a raise from `triage_document` causes `GenServer.call` to return `{:error, _}` or the call to exit, that test was encoding the bug — update its expectation. The new behavior: GenServer.call returns `{:ok, [results_for_succeeded_docs]}`, the failed doc is logged.

### Step 4 — Manual verification on the Spark

Before deploy, induce a controlled failure in production via `bin/kerf rpc` to confirm the logging works end-to-end:

```bash
ssh spark
/opt/kerf/current/bin/kerf rpc '
  # Try to triage a non-existent doc id — this raises in triage_document
  result = Kerf.Agents.EmailTriage.EmailTriage.triage(
    Kerf.Agents.EmailTriage.EmailTriage,
    ["non-existent-uuid-deadbeef"]
  )
  IO.inspect(result, label: :result)
'
# In another terminal:
journalctl -u kerf -f
# Expect: a Logger.warning line "[EmailTriage] triage_document failed for non-existent-uuid-deadbeef"
```

If the log line appears and the rpc returns `{:ok, []}` (empty results, not an exception), the fix is working in production.

## Deploy

Standard release:

```bash
cd ~/Projects/kerf/kerf
./deploy/deploy.sh
```

Watch:

```bash
ssh spark journalctl -u kerf -f
```

The deploy should be uneventful. After a few minutes of normal triage activity, the journal will look identical to before the deploy for the happy path. The new logging only fires on errors.

## Verification queries (run 7 days after deploy)

```sql
-- Count of "stranded" docs (ingested but never triaged) over the last 7 days.
-- Pre-fix baseline: ~2/week.
-- Post-fix expected: 0/week. Stranded docs should now be impossible because
-- per-doc errors no longer abort batches.
SELECT
  DATE_TRUNC('day', d.inserted_at)::date AS day,
  COUNT(*) AS stranded_count
FROM kb_documents d
WHERE d.source_type = 'email'
  AND d.inserted_at > NOW() - INTERVAL '7 days'
  AND NOT EXISTS (
    SELECT 1 FROM kb_feedback f
    WHERE f.document_id = d.id AND f.feedback_type = 'triage'
  )
GROUP BY 1 ORDER BY 1;
```

Also worth checking the journal:

```bash
ssh spark 'journalctl -u kerf --since "7 days ago" --no-pager | grep -E "triage_document failed|triage_fn failed" | wc -l'
```

A non-zero count means the new logging is catching real failures (good — they're now visible). A zero count means either no failures happened, or the fix isn't engaging — cross-reference with the stranded-doc count to disambiguate.

## Out of scope

These are real but separate:

- **Operational cleanup of the 12 stranded docs** that surfaced this bug — handle out-of-band (manual re-triage or `mix kerf.backfill_triage` if such a task exists). Not part of the code change.
- **Auto-retry of failed docs:** the fix logs and skips. A future enhancement could schedule retries via Oban for transient failures. Not in scope here because retries need a clear policy on what's retryable vs. what's permanent (a doc that always raises in `FastClassifier` due to malformed metadata should NOT be retried forever).
- **Distinguishing exception classes:** the current spec logs everything at warning/error level. A future enhancement could route specific exception classes differently (timeout → info-level + retry, DB error → warning, schema mismatch → error).
- **Gmail label-apply failures:** if `apply_gmail_actions` succeeds but Gmail-side something silently drops the label, that's a separate gap not covered here. Worth investigating if the post-fix stranded-doc count is 0 but Gmail labels are still missing.

## Why this is the right fix

- **Smallest blast radius:** two function bodies, ~20 LOC total.
- **High leverage:** the 12 stranded docs are the visible symptom; the actual gap is unknown unknowns — any new code path that raises will now be logged instead of silently swallowed.
- **No new dependencies, no schema changes, no migrations.**
- **Reversible:** revert is one symlink swap.
- **Improves operability for future debugging** — silent failures in this pipeline were a real cost when investigating today's mystery.
