# Email Routing Rules Redesign — Design

**Date:** 2026-06-22
**Status:** Approved (design)
**Scope:** Routing policy only — rewrite `priv/email_routing.exs`. No code changes
to the Router, enricher, classifier, or schema.
**Addresses:** Triage symptom (A) — important business/private mail produced no
Telegram ping while general newsletters did.

---

## 1. Problem

Surfacing to Telegram is decided entirely by the rule set in
`priv/email_routing.exs`, evaluated by `Kerf.Agents.EmailTriage.Router`
(first-matching-rule-wins on the fields `category`, `sender_type`, `urgency`,
`action`, `topic`). The legacy `PriorityScorer`→Telegram path is dead in
production (no `telegram_fn` wired in the supervisor), so the rules are the only
lever.

The live config (`version: "2026-05-11.1"`) produced inverted behaviour. Measured
on production (`email_routing_decisions`, 2026-05-15 → 2026-06-21):

- **188 pings total; 182 came from `kerf_topic_anything`** (topic contains
  `"kerf"`), of which **175 were newsletters** — the enricher LLM over-applies the
  `"kerf"` topic to general news (Süddeutsche, Politico, NYT, Guardian).
- **The intended priority rules barely fired:** `priority_high_urgency` 5,
  `priority_reply_needed` 1 — both require `sender_type="known_priority"`, which
  only 23 of 8,875 triaged emails ever had.
- **Important business/personal mail was silenced:** of ~443 business+personal
  emails, **414 went silent, only 7 pinged.** A high-urgency Datadog production
  alert (`business`, `urgency=high`, sender `known_routine`) routed to
  `default_silent`.
- **`security_alerts` is dead:** the classifier enum never emits
  `category="security"`.

## 2. Goals & non-goals

**Goals**
- Important mail pings: invoices, private (personal) messages, and
  business mail directed to the user.
- Bulk/informational mail (newsletters, marketing, social, transactional) is
  batched into the digest.
- Only spam is silenced (for now).
- Pure policy change: editable, hot-reloadable, and reversible via the operator
  override file.

**Non-goals (explicitly deferred)**
- Fixing the LLM `"kerf"` topic over-tagging at source (separate spec). Once we
  stop *routing* on the topic, the over-tagging is cosmetic, not harmful.
- Reviving the dead `PriorityScorer`→Telegram path (rejected — it would add a
  redundant second surfacing mechanism and risk double-sends).
- Adding a literal "addressed to me" recipient signal (To/CC parsing + new
  matchable field). Decided to **approximate** "to me" with existing fields
  instead; a real recipient signal would expand scope across the ingestor,
  classifier, schema, and Router.

## 3. Decisions

- **Approximate "to me specifically"** using existing fields — `category=personal`
  for private mail, and business mail qualified by action / urgency / financial
  topic. Accepted imperfection: a cold B2B email tagged `business`+`reply_needed`
  can still ping.
- **Default action flips `silent` → `digest`.** Only `spam` is silent.
- **Drop `kerf_topic_anything`** (source of the 175 spurious newsletter pings).
  Genuine Kerf-platform mail is `business`/`personal` and still pings.
- **Drop `security_alerts`** (dead rule).
- **Keep the digest delivery mechanism unchanged** (`DigestWorker` drains
  `action_taken="telegram_digest"` rows).

## 4. The rule set (new `priv/email_routing.exs`, `version: "2026-06-22.1"`)

Order matters — first matching rule wins.

| # | Rule name | Match spec | Action | Rationale |
|---|-----------|-----------|--------|-----------|
| 1 | `spam_silent` | `%{category: "spam"}` | `:silent` | Silence junk/scams **before** any ping rule (a spam "invoice" is a scam) |
| 2 | `personal_ping` | `%{category: "personal"}` | `:telegram_ping` | Private messages to the user |
| 3 | `invoice_to_pay` | `%{action: "pay"}` | `:telegram_ping` | Bills needing payment (spam already excluded) |
| 4 | `business_financial` | `%{category: "business", topic: {:contains, "financial"}}` | `:telegram_ping` | Business invoices/receipts/financial |
| 5 | `transactional_financial` | `%{category: "transactional", topic: {:contains, "financial"}}` | `:telegram_ping` | Invoices/receipts arriving as transactional |
| 6 | `business_reply_needed` | `%{category: "business", action: "reply_needed"}` | `:telegram_ping` | Business awaiting a reply |
| 7 | `business_high` | `%{category: "business", urgency: "high"}` | `:telegram_ping` | Time-sensitive business (catches the Datadog alert) |
| 8 | `business_medium` | `%{category: "business", urgency: "medium"}` | `:telegram_ping` | Moderately time-sensitive business |
| 9 | `default_digest` | `%{}` (catch-all) | `:telegram_digest` | Newsletters, marketing, social, non-financial transactional, low-urgency/cold business — everything else |

All match specs are expressible with the Router's existing matcher (equality, plus
`{:contains, item}` for list fields like `topic`; multiple keys in one rule AND
together; multiple rules OR across the set). `@valid_actions`
(`:telegram_ping`, `:telegram_digest`, `:silent`) is unchanged, and rule names are
unique (both enforced by `RoutingConfig` validation).

## 5. Expected behaviour on the audit cases

| Email | Old | New | Rule |
|-------|-----|-----|------|
| Datadog "Triggered: Automotive Cloud" (business, high) | silent | **ping** | 7 |
| Anthropic receipt (business, financial) | silent | **ping** | 4 |
| Cold "Aluminum Extrusion Profiles" (business, unknown_human, low, schedule) | silent | **digest** | 9 |
| Süddeutsche / Politico / Guardian newsletters (kerf-tagged) | ping | **digest** | 9 |
| A personal message | (varies) | **ping** | 2 |
| Spam (e.g. lexa.nl promo) | silent | **silent** | 1 |

Expected volume shift: pings rise from ~188 to an estimated few-hundred over a
comparable window (~10–15/day of genuinely relevant mail); newsletters
(~6,571) move into the digest; spam (~1,527) stays silent.

## 6. Known imperfections / tunables (revisit after observing real traffic)

- **Rule 8 (`business_medium` → ping):** medium-urgency business pings. Drop this
  rule if medium-urgency business proves noisy and should digest instead.
- **Cold B2B that gets tagged `business`+`reply_needed`** will ping (rule 6) — the
  accepted cost of approximating "to me" without a recipient signal.
- **Digest volume:** with the default flipped to digest, transactional noise
  ("package shipped", "password changed") now enters the digest. If noisy, move
  `social`/`marketing`/some `transactional` to `:silent` in a later tune.

## 7. Testing approach

Pure, deterministic, DB-free. Add a test that loads the real
`priv/email_routing.exs` via `Code.eval_file/1` and, for a table of
representative records (the audit cases above), asserts the resolved action by
walking the rules with the public `Router.matches?/2` (first match wins).

Test cases (minimum):
- spam → `:silent`
- personal → `:telegram_ping`
- business + high urgency → `:telegram_ping` (Datadog)
- business + topic financial → `:telegram_ping` (receipt/invoice)
- action `pay` → `:telegram_ping`
- business + reply_needed → `:telegram_ping`
- business + medium urgency → `:telegram_ping`
- cold business (low urgency, action fyi/schedule, no financial topic) → `:telegram_digest`
- newsletter (incl. one with topic `["kerf", ...]`) → `:telegram_digest`
- transactional non-financial → `:telegram_digest`
- config validity: `RoutingConfig` accepts the new file (unique names, valid
  actions, version present).

Existing `Router` matcher/`pick_rule` behaviour and `RoutingConfig`
loading/validation are already covered by `router_test.exs` /
`routing_config_test.exs` and are not modified.

## 8. Rollout & reversibility

- Ships as the release default `priv/email_routing.exs`. No operator override
  exists on the spark today, so the new default goes live on deploy/reload.
- `RoutingConfig` watches the override path and hot-reloads on change; the rules
  can be tuned in production by writing `/opt/kerf/email_routing.exs`, and
  reverted by removing it.
- Fully reversible: restore the previous file contents (`version: "2026-05-11.1"`)
  to roll back.
