# SPEC A — Self-originated mail must never ping

**Concern (single):** Mail you send must not produce a Telegram ping. It may still be
ingested (thread context preserved) — the fix is a routing decision, not an ingestor filter.

**Symptom:** Telegram pings arrive for mail that "looks like I received it myself."

**Branch:** `feat/self-sender-silence`
**Status:** draft, written from remembered contract — DO NOT write RED until §1 read-back reconciles.

---

## 0. Why this is scoped the way it is

"It looks like I received the mail myself" is ambiguous between two different bugs:

- **Case A — real self-send ping.** A message *you sent* entered triage and matched a ping
  rule (broadened `business_*`/`personal_*`/`reply_needed_*` rule, or thread-aware priority
  propagation firing on your own reply inside a priority thread). Fix: a top-priority
  `self_sent → :silent` routing rule. **This spec covers Case A only.**
- **Case B — misattribution.** A *received* message is being summarised/attributed to you —
  e.g. `feat/body-prep-extraction` (the recent enricher change) picking the wrong message in a
  thread as "the email," so the surfaced sender/summary reads as yours. Fix: enricher
  attribution, a *different* spec. **If §1 shows Case B, stop and flag — do not apply this spec.**

§1 exists to decide which case you're in before any code moves.

---

## 1. Contract read-back (Claude Code, read-only, report — no changes)

Report each verbatim; do not write tests until this reconciles with the assumptions in §2/§3.

1. **Ingestion path.** How does the ingestor fetch mail — `is:unread` search, historyId
   incremental sync, or thread-level ingestion? Quote the actual Gmail query / sync call in the
   ingestor. (If `is:unread` only, self-sent mail should never appear — which points at Case B.)
2. **Which message pinged.** For a recent offending ping, find the triage row
   (`kb_feedback`, `feedback_type='triage'`, JSONB `context`) joined to `kb_documents`. Report:
   the `from` on the surfaced `kb_documents` row, the message's Gmail labels if available, and
   whether that `from` is your own address. **This is the Case A vs Case B decision.**
3. **Router match space.** In `priv/email_routing.exs`, quote two or three representative rules
   and the final catch-all. Report the exact rule map keys (expected: `name`, `action`, `match`)
   and — critically — **what fields a `match` can key on**: does the feature set the router sees
   include a raw `from`/`sender_email`, or only derived labels (`category`, `sender_type`,
   `urgency`, `action`)? Quote the struct/map the router receives in `pick_rule/2`.
4. **Evaluation order.** Confirm `Router.pick_rule/2` is first-match-wins, top-to-bottom
   (router.ex ~77–86). Quote the relevant lines.
5. **Config version.** Report the current config version string (the redesign shipped
   `2026-06-22.1`) — the GREEN commit bumps it.
6. **Self addresses.** List every address you send from (primary + aliases). This is the data
   the rule keys on; missing an alias = a leaking ping.

**If (2) shows the pinged `from` is a received sender, not you → Case B → STOP.** Report and
hand back for an enricher-attribution spec instead.

---

## 2. Design (assuming Case A confirmed)

Match on a **derived boolean, not a literal address**, to keep the config free of hardcoded
strings and robust to alias changes:

- Add `config :kerf, :self_addresses, ["widojansen@gmail.com", ...]` (fill from §1.6).
- Where the router's input features are assembled (enricher or router entrypoint — §1.3
  determines which), compute `is_self` = `from ∈ :self_addresses` (case-insensitive, trimmed).
- Add a routing rule as the **first** rule in `priv/email_routing.exs`:

  ```
  %{name: "self_sent", action: :silent, match: %{is_self: true}}
  ```

First-match-wins (§1.4) means this pre-empts every ping rule, including thread-aware priority
propagation — which is exactly the regression that must hold.

If §1.3 shows the match space *cannot* carry a derived boolean and only sees raw `from`, fall
back to matching the address literal(s) in the rule, but still source them from
`:self_addresses` config rather than inlining — one place to maintain.

---

## 3. RED (routing policy suite — deterministic, seed-stable by construction)

Write from the §1 contract, not from this doc. Assert on `Router.pick_rule/2`:

1. Email features with `is_self: true` → selected rule is `self_sent`, `action: :silent`.
2. **Regression guard for the actual bug:** `is_self: true` **AND** a priority-thread condition
   that would otherwise fire `priority_*` → still `self_sent`/`:silent` (proves it's first).
3. `is_self: false` on an otherwise-identical email → does **not** match `self_sent` (no
   over-capture; a normal received email is unaffected).
4. Case-insensitivity / whitespace: `From: WidoJansen@Gmail.com ` → `is_self: true`.

RED committed alone. No implementation in this commit.

## 4. GREEN

`:self_addresses` config + `is_self` feature computation + the `self_sent` rule (first) +
config-version bump. No test edits. Separate commit from RED.

## 5. Verify (post-GREEN, before deploy)

- Full routing suite green in your Postgres env.
- Read-back: quote the first rule in `email_routing.exs` and confirm it's `self_sent`.
- Post-deploy observation: send yourself a test mail / reply in a known priority thread →
  confirm no ping, and (if applicable) confirm the message still ingested (thread node present).

## 6. Data-contract / caution notes

- `email_routing.exs` is code-tracked in `priv/` → rides in the GREEN commit; no git-invisible
  data change here (unlike the `known_priority` marking, item N).
- Don't rename existing rule names — dashboards/analytics key ping-distribution on them.
- The address list is now a small data-contract: adding/removing a send-from alias later means
  editing `:self_addresses`, not the rule.
