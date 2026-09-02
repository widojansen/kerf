# SPEC C — Notify Guard — Cycle 2 addendum (Router seam)

**Supersedes** the seam assumptions in the base spec (`spec-c-notify-guard.md`) §1 and §6.
The base spec assumed `EmailTriage.send_notifications/2` was the live emitter. **Verified
false on `main`:**

- `telegram_fn` is never injected for `EmailTriage` (the only `telegram_fn` in `lib/` is in
  `service_health/monitor_worker.ex`, an unrelated subsystem). So `send_notifications/2` is
  **dead in production**.
- Live notification path:
  `Enricher` (`enricher.ex:120` → `Router.new(unique: false)`) enqueues a `Router` Oban job →
  `Router.perform` → `handle_record/1` on `triage_status="enriched"` records does
  `pick_rule/2` → `insert_decision!/4` → `deliver(action, record)`.
  `Router.deliver(:telegram_ping, _)` is the real sender (overridable `telegram_sender()`,
  `router.ex` ~L168–170: `Application.get_env(:kerf, Kerf.Agents.EmailTriage.Router, [])[:telegram_sender]`).

The pure guard (`NotifyGuard.notify?/2`, Cycle 1) is unchanged. Only the **wiring target**
moves from `send_notifications/2` to the Router.

---

## Gate point (settled)

In `Router.handle_record/1` (the `"enriched"` clause), **after** `pick_rule/2` and **before**
`insert_decision!` + `deliver`:

1. Load the `Document` via `record.document_id` (this FK exists — it's the OrphanQuery
   anti-join key). If `deliver` already loads the Document for formatting, hoist that single
   load and reuse it.
2. Extract `labels = doc.source_metadata["labels"]`, `date = doc.source_metadata["date"]`.
3. If `NotifyGuard.notify?(%{labels: labels, date: date}, now) == false` → override
   `action_atom = :silent`. (Guard can only **silence**, never un-silence.)
4. `insert_decision!` records the possibly-overridden `action_taken`. A guard-silenced record
   persists `action_taken="silent"`, so:
   - the cron `DigestWorker` (`WHERE action_taken="telegram_digest"`) cannot resurface it, and
   - `deliver(:silent, _)` is a no-op.
5. Keep the matched `rule_name` intact (do **not** mangle it). Emit a log/telemetry line on
   guard-driven silence carrying the reason (sent-label vs stale) for soak visibility.

**`now` seam:** add an injectable clock —
`Application.get_env(:kerf, Kerf.Agents.EmailTriage.Router, [])[:now_fn] || (&DateTime.utc_now/0)`
— so the guard's clock is deterministic in tests.

---

## Explicitly unchanged

- `EmailTriage.send_notifications/2` — **DEAD**; do **not** gate. Flag in the PR as a
  separate-cleanup candidate (removal/rewire is its own single-concern change; whoever does it
  must not reintroduce an ungated notifier).
- `triage_document/2` — **not** enriched. Base-spec finding (b) is moot: the Router sources
  labels+date from the Document, not from the in-memory result.
- `Reconciler`, `ReconcileDoc`, `OrphanQuery` — untouched.

---

## Cycle 2 RED (Router-level)

Spy via the injectable `telegram_sender` (`Application.put_env(:kerf, Router, telegram_sender: spy)`)
and the `now_fn` seam. Reuse Cycle 1's fixed `now = ~U[2026-04-01 12:00:00Z]`. Build an
enriched `TriageRecord` linked to a `Document` whose `source_metadata` carries the labels/date
under test. `async: false` (mutates Router app env).

- `sent_label_silenced` — doc labels `["SENT","INBOX"]`, matched rule would ping →
  decision `action_taken="silent"`, `telegram_sender` **not** called.
- `stale_silenced` — doc date `now−48h`, rule would ping → `action_taken="silent"`, no send.
- `recent_inbox_pings` — doc labels `["INBOX"]`, date `now−1h`, rule → `:telegram_ping` →
  `telegram_sender` called once, `action_taken="telegram_ping"`.
- `guard_only_silences` — a rule that already yields `:silent` stays `:silent` (no crash, no
  un-silence).
- `silenced_excluded_from_digest` — a guard-silenced record does **not** get
  `action_taken="telegram_digest"` (DigestWorker exclusion holds).

Skeleton for RED: the `now_fn`/guard call site raises or is stubbed such that these assertions
fail for the intended (feature-missing) reason, seed-stable. Stop at RED.

---

## Cycle 2 GREEN

Implement the override in `handle_record/1` + the `now_fn` seam per above. No test edits.

---

## Date-parser consolidation (check, don't block)

`TelegramFormatter` renders "Mail received …" and likely already parses the RFC2822 `Date`
header. If a clean shared helper exists, `NotifyGuard.parse_date/1` should reuse it rather than
carry a second parser. Confirm during Cycle 1/2; consolidation can be a small follow-up, not a
Cycle 2 blocker.

---

## Commit plan (revised for the Router seam)

- `test: RED silence self-sent/stale at Router` → `feat: GREEN gate Router action (+ now_fn seam)`

Single-concern; RED and GREEN separate; Wido runs all git + systemctl.
