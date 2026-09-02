# SPEC C — Amendment: Notify Guard (silent-route for self-sent + stale mail)

Status: ready for RED
Depends on: SPEC C Part 2 (reconciler) — already shipped on `main`
Owner path: `~/Projects/kerf/docs/specs/`

---

## 1. Problem (grounded in current `main`)

Two notification defects, one shared root cause — **the triage notification path fires for
mail it should stay silent about**:

1. **Backlog spam.** `Reconciler` (cron `*/10`, shipped merge `2efcf38`) recovers orphaned
   email docs by calling the *live* triage path, `EmailTriage.triage/2`. That path ends in
   `send_notifications/2`, so every recovered orphan emits a "New email…" Telegram message
   bearing its original receipt date (May 14, Jul 5, …).
2. **Self-sent mail pings.** The live ingestor uses Gmail **history sync**
   (`messagesAdded`), which includes messages you send. There is **no self-sender filter
   anywhere** in the pipeline, so your own mail is classified "Familiar sender" and pinged.

Confirmed facts the fix relies on:
- Ingested docs store raw Gmail label IDs verbatim: `source_metadata["labels"]`
  (`gmail_client.ex`: `labels: msg["labelIds"] || []`). Sent mail carries `"SENT"`.
- The received date is stored as the RFC2822 `Date` header string in
  `source_metadata["date"]` (`email_ingestor.ex` `insert_email_document/3`).
- The **active** emission site is `EmailTriage.send_notifications/2`
  (`email_triage.ex` ~L256–269): high-priority → individual `format_high_priority`
  messages; low-priority → batched `format_digest`. Both go through `state.telegram_fn`.
- `Router` (`router.ex`, `:telegram_ping` / `:telegram_digest` / `:silent`) is a separate
  Step-12 routing subsystem and appears **not** to be on the triage→notify path — this must
  be confirmed during implementation (see §6).

---

## 2. Decision

Introduce **one universal notification guard**, applied at the emission seam, that forces
silence when **either** condition holds:

```
notify?  ==  NOT ("SENT" ∈ labels)  AND  (received_date ≥ now − MAX_AGE)
```

- `MAX_AGE` default **24h** (configurable).
- Applied uniformly to the live and reconcile paths (both go through
  `send_notifications/2`), so no `mode:` flag is threaded.

Resulting behaviour:
| Case | Outcome |
|---|---|
| Weeks-old backlog recovered by reconciler | triage row written, **no ping** |
| Recent mail dropped by a crash, then recovered | **pings** (reconciler's actual purpose) |
| Your own sent mail (any alias), any path | **never pings** |
| Normal fresh inbound mail | pings as today |

The triage record, routing-decision row, gmail-label actions, and enrichment enqueue are all
**still written** — only Telegram delivery is suppressed. So the KB/audit stay intact and
silenced docs do not churn back as false orphans.

---

## 3. Scope

**In scope**
- New pure module `Kerf.Agents.EmailTriage.NotifyGuard`.
- Wiring it into `send_notifications/2` (filter before the high/low split).
- Ensuring each triage `result` exposes `labels` + `date` (enrich if it does not).
- Confirming/gating the `Router` deliver path *iff* it is live (see §6).

**Out of scope (deferred — do NOT touch)**
- `OrphanQuery` scope narrowing. With this guard the broad anti-join is a *cost* concern
  (LLM compute to silently backfill history), not a correctness one. Tracked separately.
- `Reconciler` / `ReconcileDoc` — **no changes**. `ReconcileDoc.perform` still receives
  `{:ok, [record]}` from triage (the guard only affects delivery, not the returned list).

---

## 4. The guard contract

New module `lib/kerf/agents/email_triage/notify_guard.ex`.

```elixir
@spec notify?(input :: map(), now :: DateTime.t()) :: boolean()
# input is a superset of a triage result; only these keys are read:
#   :labels => [String.t()]        (from source_metadata["labels"])
#   :date   => String.t() | nil    (RFC2822 Date header from source_metadata["date"])
# extra keys ignored.
```

Rules, evaluated in order:
1. `"SENT" in labels` → `false`.  (never announce your own sent mail; covers all aliases)
2. Parse `:date`:
   - parse fails **or** `nil` → `true` (**fail-open**: a live mail with a malformed/absent
     header should still reach you; malformed dates in the historical backlog are rare, and
     rule 1 + the one-time nature of backlog drain bound the blast radius). Log at `:debug`.
   - `received_at < now − MAX_AGE` → `false`.
   - else → `true`.

Config (tunable, no redeploy):
```elixir
Application.get_env(:kerf, Kerf.Agents.EmailTriage.NotifyGuard, [])
|> Keyword.get(:max_age_hours, 24)
```

Date parsing: **reuse any existing RFC2822 / `Date`-header parser** already in the tree
(check `TelegramFormatter` — it already renders "Mail received …" — and ingestor utils). If
none exists, add a small pure parser (no new deps) with its own tests folded into RED. Do not
add Timex for this.

---

## 5. RED

Two single-concern cycles. RED = failing tests + raising skeleton(s), seed-stable, **no
production logic**. Stop at RED; re-run independently before GREEN is authorized.

### Cycle 1 — pure guard
Skeleton: `NotifyGuard.notify?/2` that raises `"not implemented"`.
`test/kerf/agents/email_triage/notify_guard_test.exs`, all with a **fixed** `now`:

- `sent_label_is_silent` — labels `["SENT","INBOX"]`, recent date → `false`
- `sent_label_silent_without_date` — labels `["SENT"]`, date `nil` → `false`
- `stale_is_silent` — labels `["INBOX"]`, date `now−48h` → `false`
- `boundary_inside_window_notifies` — date `now−23h` → `true`
- `boundary_outside_window_silent` — date `now−25h` → `false`
- `recent_inbox_notifies` — labels `["INBOX"]`, date `now−1h` → `true`
- `nil_date_non_sent_notifies` — labels `["INBOX"]`, date `nil` → `true` (fail-open)
- `unparseable_date_non_sent_notifies` — date `"garbage"` → `true`
- `window_configurable` — override `max_age_hours: 12`, date `now−13h` → `false`

If a new date parser is added, include its own RED cases (valid RFC2822 → correct UTC;
malformed → `:error`).

### Cycle 2 — integration at the emission seam
Uses the existing injectable `telegram_fn` (init opt) as a spy (send to `self()`).

- `suppresses_self_sent` — a triage run yielding one `SENT`-labelled result and one recent
  inbox result → `telegram_fn` invoked **only** for the inbox result.
- `suppresses_stale` — a `now−48h` inbox result → `telegram_fn` **not** invoked.
- `still_pings_recent_inbox` — a `now−1h` inbox result → `telegram_fn` invoked once.
- `silent_excluded_from_digest` — a low-priority stale/self-sent result does **not** appear
  in the `format_digest` batch.

If the triage `result` does not already carry `:labels` and `:date`, this cycle also adds a
failing test asserting the result exposes them (enriched in `triage_document/2` from
`doc.source_metadata`), then the enrichment is implemented in GREEN.

---

## 6. GREEN

- Implement `NotifyGuard.notify?/2` per §4.
- In `send_notifications/2`: filter results through the guard **before** the high/low split,
  passing `now`, e.g. `notifiable = Enum.filter(results, &NotifyGuard.notify?(&1, now))`.
  Silent results are thereby dropped from **both** the individual high-priority sends and the
  low-priority digest.
- Ensure each `result` carries `:labels` and `:date` (enrich in `triage_document/2` if
  needed; source from `doc.source_metadata["labels"]` / `["date"]`).
- **Router check (must do):** confirm whether `Router.deliver(:telegram_ping, _)` /
  `:telegram_digest` execute on the live/reconcile flow.
  - If **yes** → apply the same `NotifyGuard` so guarded mail resolves to the `:silent`
    action (routing-decision row still recorded, never delivered) so the cron `DigestWorker`
    (`email_routing_decisions WHERE action_taken="telegram_digest"`) cannot resurface it.
  - If **no** (dead/parallel path) → note it in the PR and leave a one-line guard comment at
    the deliver site; do not wire new behaviour.
- No changes to `Reconciler`, `ReconcileDoc`, `OrphanQuery`.
- No test edits between RED and GREEN.

---

## 7. Done criteria

- Full suite green; RED→GREEN with zero test edits (pre-commit hook must pass).
- Post-deploy soak (see §8):
  - Draining the orphan backlog writes triage rows with **zero** Telegram sends for
    mail older than 24h.
  - A freshly sent mail from any of your aliases → **no** ping.
  - A genuinely-recent non-self inbound mail → **pings** as before.

---

## 8. Rollout

1. Keep `:email_reconcile` **paused** (already done via console) until GREEN deploys.
2. Deploy GREEN.
3. Resume: `Oban.resume_queue(queue: :email_reconcile)`.
4. Backlog then drains silently; watch the soak criteria in §7.

---

## 9. Commit plan

- `test: RED notify_guard pure rules` → `feat: GREEN notify_guard` 
- `test: RED silence self-sent/stale at send_notifications` → `feat: GREEN gate send_notifications (+ result enrichment)`

Single-concern each; RED and GREEN separate; Wido runs all git + systemctl.
