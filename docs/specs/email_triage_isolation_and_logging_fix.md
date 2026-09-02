# Spec — EmailTriage batch isolation and ingestor exception logging

## Status

- **Type:** Bug fix
- **Components:** `Kerf.Agents.EmailTriage.EmailTriage`, `Kerf.Ingestors.Email.EmailIngestor`
- **Workflow:** TDD (Red → Green → Refactor)
- **Estimated scope:** 2 functions modified, ~5 new test cases, ~30 LOC change
- **Deploy impact:** Mix release rebuild + symlink swap; no migrations; no env changes

## Context

Phase B email triage is running in production with healthy throughput (~235 emails/day, weeks of uptime). Production audit on 2026-05-17 found a steady trickle of "missed" emails — documents that sit in `kb_documents` with **no corresponding `kb_feedback` row** and **no Gmail label applied**. The user notices them in Gmail because they remain unread and unlabeled while surrounding messages get the expected `Kerf/Newsletter`, `Kerf/Spam`, etc. labels.

Database evidence (collected 2026-05-17):

- 11 stranded documents accumulated since 2026-04-09 (~5 weeks)
- ~2 per week, sometimes paired in time (multiple docs ingested seconds apart, all stranded together)
- Manual re-triage of stranded docs **succeeds cleanly** — there's nothing structurally wrong with the documents themselves
- The paired-in-time pattern is the smoking gun: same Gmail poll batch → same `triage_fn` call → batch crash → all docs in batch stranded

## Root cause

Two cooperating issues in the EmailIngestor → EmailTriage handoff:

### Issue 1: `triage_document/2` exception un-isolated within a batch

`Kerf.Agents.EmailTriage.EmailTriage.handle_call({:triage, document_ids}, ...)` processes the batch as:

```elixir
results =
  document_ids
  |> Enum.flat_map(fn doc_id -> triage_document(doc_id, state) end)
```

If `triage_document/2` raises for one doc, `Enum.flat_map` propagates the exception out of the handler. The GenServer.call at the caller site raises. **None of the docs in the batch get triaged**, even ones that would have succeeded on their own.

`triage_document/2` has many places that can raise:
- `repo.get/2` — DB timeout
- `get_document_embedding/2` — DB query
- `InterestMatcher.match_interests/3` — pgvector query
- `FastClassifier.classify/2` — DB lookups (sender), pattern matches
- `state.classifier_fn.(...)` — vLLM HTTP call, JSON parsing
- `apply_gmail_actions/5` — Gmail HTTP API
- `record_triage_feedback/3` — DB insert
- `write_triage_record_and_enqueue/4` — Repo.transaction

Any of these failing for one doc destroys the batch.

### Issue 2: EmailIngestor's `rescue _ -> :ok` swallows everything silently

`Kerf.Ingestors.Email.EmailIngestor.do_sync/1` (around line 233) wraps the triage call as:

```elixir
if doc_ids != [] and state.triage_fn do
  try do
    state.triage_fn.(Enum.reverse(doc_ids))
  rescue
    _ -> :ok   # bare wildcard, no logging
  end
end
```

A bare `rescue _ -> :ok` is opaque. No exception type, no stacktrace, nothing in the journal. The 11 stranded docs accumulated over 5 weeks without a single error log line — that's how Issue 2 amplifies Issue 1.

## What "fixed" looks like

After the fix:

1. **One bad email in a batch does not strand its siblings.** `triage_document/2` exceptions are caught inside the `Enum.flat_map`, logged, and the doc is skipped while the rest of the batch proceeds.
2. **The EmailIngestor's exception swallow logs before continuing.** Bare `rescue _ -> :ok` becomes `rescue e -> Logger.error(...)`. The poll loop still continues (we don't want a single bad batch to crash the GenServer), but exceptions become visible in the journal.
3. **No behavioral regression for the happy path.** Successful batches produce identical output. The fix is purely additive (try/rescue wrappers + logging).
4. **The stranded-doc accumulation rate drops to zero** for cases that match these failure modes. There may still be genuinely-broken docs that fail on every retry — those will at least be visible in logs now.

## TDD sequence

### Step 1 — RED: write the failing tests

Two test files to update.

#### `test/agents/email_triage/email_triage_test.exs`

Find the test module describing the `:triage` GenServer call. Add a new describe block:

```elixir
describe "triage/2 batch isolation" do
  test "one raising document does not prevent processing of siblings" do
    # Arrange three doc ids. Stub the path so that the middle doc raises.
    # The implementation detail of "how to make triage_document raise" depends
    # on what the test setup looks like; the easiest hook is probably a
    # classifier_fn stub that raises for one specific doc title or sender.

    {good1_id, bad_id, good2_id} = prepare_three_docs_one_bad()

    {:ok, results} =
      EmailTriage.triage(EmailTriage, [good1_id, bad_id, good2_id])

    # Both good docs should be triaged.
    assert Enum.any?(results, &(&1.document_id == good1_id))
    assert Enum.any?(results, &(&1.document_id == good2_id))

    # Bad doc is absent from results (not raised, not blocking).
    refute Enum.any?(results, &(&1.document_id == bad_id))
  end

  test "raising document is logged with doc_id and exception" do
    {_good_id, bad_id, _} = prepare_three_docs_one_bad()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        EmailTriage.triage(EmailTriage, [bad_id])
      end)

    assert log =~ "triage_document"
    assert log =~ bad_id
    # Check that some indication of "exception" or the specific error string is present.
    assert log =~ ~r/exception|error|failed/i
  end
end
```

The `prepare_three_docs_one_bad/0` helper is test-suite-specific — adapt to whatever fixture pattern the existing tests use. The point is: three docs, one of them poisons `triage_document/2`.

#### `test/ingestors/email/email_ingestor_test.exs`

Find the test module covering `do_sync/1` or the `triage_fn` invocation. Add:

```elixir
describe "triage_fn exception handling" do
  test "exception from triage_fn is logged, not silently swallowed" do
    # Stub triage_fn to always raise.
    raising_triage_fn = fn _doc_ids -> raise "synthetic failure" end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # Trigger a sync that ingests at least one doc, so do_sync hits
        # the triage_fn branch.
        run_one_sync_with_triage_fn(raising_triage_fn)
      end)

    assert log =~ "synthetic failure"
    # Check that the GenServer survives (it did not crash; subsequent
    # state operations still work).
    assert is_pid(Process.whereis(EmailIngestor))
  end

  test "exception from triage_fn does not block subsequent polls" do
    # The ingestor should keep polling after a failure.
    # Trigger sync that raises, then a second sync that succeeds.
    # Both syncs should run.
    ...
  end
end
```

Run: `mix test test/agents/email_triage/email_triage_test.exs test/ingestors/email/email_ingestor_test.exs`
Expected: the new tests fail (current implementation either crashes the whole batch or swallows silently with no log). **Confirm RED before continuing.**

### Step 2 — GREEN: minimal implementation

#### Fix 1 — `lib/kerf/agents/email_triage/email_triage.ex`

In `handle_call({:triage, document_ids}, ...)`, wrap the per-doc call with try/rescue:

```elixir
def handle_call({:triage, document_ids}, _from, state) do
  results =
    document_ids
    |> Enum.flat_map(fn doc_id ->
      try do
        triage_document(doc_id, state)
      rescue
        e ->
          Logger.error(
            "triage_document failed for doc_id=#{doc_id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
          []
      catch
        kind, value ->
          Logger.error(
            "triage_document caught #{kind} for doc_id=#{doc_id}: " <>
              inspect(value, limit: 200)
          )
          []
      end
    end)

  new_state = %{state | documents_triaged: state.documents_triaged + length(results)}
  {:reply, {:ok, results}, new_state}
end
```

Notes:
- Both `rescue` (Elixir exceptions) and `catch` (BEAM-level throws/exits) are covered. A `GenServer.call` timeout, for example, surfaces as `:exit` not as an exception.
- The doc is skipped silently from the result list but loudly in the log.
- `Logger` is already required by this module (verify; if not, add `require Logger` near the top).

#### Fix 2 — `lib/kerf/ingestors/email/email_ingestor.ex`

Replace the bare `rescue _ -> :ok` around line 233:

```elixir
if doc_ids != [] and state.triage_fn do
  try do
    state.triage_fn.(Enum.reverse(doc_ids))
  rescue
    e ->
      Logger.error(
        "EmailIngestor: triage_fn raised for batch of #{length(doc_ids)} docs: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  catch
    kind, value ->
      Logger.error(
        "EmailIngestor: triage_fn caught #{kind} for batch of #{length(doc_ids)} docs: " <>
          inspect(value, limit: 200)
      )
  end
end
```

Notes:
- The outer wrapper stays — we don't want one bad batch to crash the GenServer's poll loop. Defense in depth: Fix 1 prevents most batch failures, Fix 2 logs the rest.
- Logging the batch size gives operators a quick sense of blast radius.
- `Logger` may already be required in this module (verify).

Run: `mix test test/agents/email_triage/email_triage_test.exs test/ingestors/email/email_ingestor_test.exs`
Expected: new tests pass. **Confirm GREEN before continuing.**

### Step 3 — REFACTOR

Run the full suite:

```
mix test
```

Watch for any test that previously assumed "triage_fn raises = nothing happens" — those assumptions are still true (the function returns `:ok`-equivalent), but the log output is now present. If a test was using `capture_log` and asserting it was empty, that test was encoding the bug and needs updating.

There should be no regressions in the LLM-path, FastClassifier, or any other downstream behavior — the wrappers only change error paths.

### Step 4 — Manual verification on Spark (post-deploy)

After deploy, monitor for a day:

```bash
# Are stranded docs accumulating?
ssh spark 'export PATH=$HOME/.asdf/shims:$PATH && psql kerf_prod -At -c "SELECT COUNT(*) FROM kb_documents d WHERE d.source_type = '\''email'\'' AND NOT EXISTS (SELECT 1 FROM kb_feedback f WHERE f.document_id = d.id AND f.feedback_type = '\''triage'\'') AND d.inserted_at > NOW() - INTERVAL '\''24 hours'\'';"'
```

Expected: 0 stranded docs in the 24h window after deploy (was running at ~2 per week pre-fix, but the variance is high enough that 24h is the right window to draw conclusions only when we see the journal logs).

```bash
# Look for the new log lines
ssh spark 'journalctl -u kerf --since "24 hours ago" --no-pager | grep -E "triage_document failed|triage_fn raised|triage_fn caught"'
```

Expected: occasional lines when genuine failures occur (e.g., vLLM hiccup, Gmail API rate-limit). If logs show repeated failures for the same doc_id, that's a genuinely broken document and needs separate investigation.

## Deploy

Standard:

```bash
cd ~/Projects/kerf/kerf
./deploy/deploy.sh
```

No DB migration. No env change. Restart is the only risk, and we have a rollback symlink.

## Out of scope (explicit)

- **Re-triaging the existing 11 stranded docs.** Done manually outside this spec via a one-off `bin/kerf rpc` script. Not part of the code change.
- **Retry queue for failed docs.** Worth considering eventually (a stranded doc currently has no automatic retry path; it sits in `kb_documents` forever until someone manually re-triages). Out of scope for this fix because it requires a new schema or a state field. File as a follow-up.
- **Reducing batch size or switching to per-doc concurrency.** The current batch model works fine when individual docs don't crash. Don't change the architecture in this PR.
- **Alerting on stranded-doc accumulation.** Worth wiring once the logging exists, as a follow-up.

## Why this is the right fix to ship next

- **Small, surgical, reversible.** Two `try/rescue` wrappers and a logging addition. No data model changes.
- **Strictly additive on the happy path.** No risk to throughput, latency, or correctness for successful triages.
- **Closes a class of silent-data-loss bugs.** The 11 stranded docs over 5 weeks is a real visible symptom; the architectural fix should prevent recurrence and surface anything we don't yet understand.
- **Logging is free.** Even if the isolation never fires in practice, just being able to see `triage_fn raised` in journalctl is operationally valuable.
