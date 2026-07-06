# SPEC B — Inline transactional itemisation in the digest

**Concern (single):** The digest lists every `transactional` email individually (sender +
subject + time) so a missed one is visible at a glance. All other categories stay as counts.

**Symptom:** The digest is count-only; you can't see whether a transactional was missed
(the mijndomein.nl "miss" was in the digest, just not itemised).

**Decision (locked):** Inline itemisation for `transactional` only. Other categories remain
counts. `/digest_full` (deferred item L) is a *separate* follow-up, not this spec.

**Branch:** `feat/digest-transactional-inline`
**Status:** RECONCILED against Claude Code §1 read-back on 2026-07-02. The reconciled contract
below supersedes the original §1.2/§2 assumptions, which were provably wrong (see reconciliation
note). Single RED→GREEN pair, spanning **two modules**.

---

## Reconciliation note (2026-07-02)

The §1 read-back corrected six assumptions. What actually holds:

1. **Two modules, one concern.** `digest_worker.ex` projects `RoutingDecision` records down to
   `%{name, category}`, discarding everything else. The fix extends that projection (for
   transactional only) *and* the renderer in `telegram_formatter.ex`. Single pair, two modules —
   there is **no counts-only accumulator and no migration** (the per-email data already exists on
   `RoutingDecision` + its `source_metadata`; the projection just throws it away).
2. **No `subject`/`from`/`sender` columns on `kb_documents`.** All of it lives in the
   `source_metadata` JSON map. subject = `source_metadata["subject"]` (fallback `title`);
   sender = `source_metadata["sender_name"]` (fallback `source_metadata["sender"]`).
3. **Timestamp = `RoutingDecision.inserted_at` (UTC), not the email's `date` header.** The header
   is sender-controlled and often malformed; `inserted_at` is always present and within one
   poll-cycle of receipt. Local-tz display is **new work** — no tz conversion exists in the path
   today (hence the `:tz` prerequisite, §0).
4. **Over-limit is currently a silent hard `String.slice` to 4096 + "...".** §2's cap-then-`+M
   more` guard is new logic replacing that, not a tweak.
5. **Empty case has no current analog.** Today an empty item list makes the whole digest nil
   (skipped), and a zero-count category simply never appears (`group_by` omits absent keys).
   `Transactional: none` on an otherwise-non-empty digest is new logic.
6. **Cap collision.** The renderer already caps *every* category at 3 names + `+N more`.
   Transactional must **override** that with full per-item lines up to 40, then `+M more`.

---

## 0. Prerequisite — time-zone database + digest config

Local-time display needs a named-zone tz database. **The repo already carries `:tz`**
(`{:tz, "~> 0.28"}`, resolved 0.28.1) — a compile-time IANA database, distinct from `tzdata`.
Decided: use the existing `:tz`, do **not** add `tzdata` (running both would be dead weight).

**Deployed-state check (2026-07-02, in the running prod release via `bin/kerf remote`):**

- tz database is LIVE and verified in prod — `DateTime.shift_zone/2` returns `09:14` CEST for the
  `07:14Z` sample inside the running node. `config :elixir, :time_zone_database,
  Tz.TimeZoneDatabase` is already set and deployed. No action.
- `:kerf, :digest` config is **NOT set** — `Application.get_env(:kerf, :digest)` returns `nil` in
  prod. This is the one remaining prerequisite: add the keys (build-time `config.exs`, so they
  land with the GREEN release build/deploy — prod keeps returning `nil` until then).

```elixir
# config/config.exs  — ADD (rides in / just before GREEN)
config :kerf, :digest,
  display_tz: "Europe/Amsterdam",
  transactional_inline_cap: 40
```

**GREEN must read defensively regardless** — this `nil` is exactly the belief-vs-artifact gap to
guard against, and a future missing-config must never crash the digest:

```elixir
digest_cfg = Application.get_env(:kerf, :digest, [])          # note the [] default, not nil
tz  = Keyword.get(digest_cfg, :display_tz, "Europe/Amsterdam")
cap = Keyword.get(digest_cfg, :transactional_inline_cap, 40)
```

Verified in prod (`bin/kerf remote`):

```elixir
{:ok, dt} = DateTime.shift_zone(~U[2026-07-02 07:14:00Z], "Europe/Amsterdam")
# => {:ok, #DateTime<2026-07-02 09:14:00+02:00 CEST Europe/Amsterdam>}   (07:14Z → 09:14 CEST)
Calendar.strftime(dt, "%H:%M")  # => "09:14"    ✓
Application.get_env(:kerf, :digest)  # => nil   (keys not yet added — see above)
```

`DateTime.shift_zone/2` is database-agnostic — it uses whatever `:time_zone_database` is set, so
the render path is identical regardless of `:tz` vs `tzdata`.

**Why `:tz` is the right fit here (no autoupdate concern):** `:tz` compiles the IANA data in at
build time and wants no writable runtime dir, so the `ProtectHome=yes`/`PrivateTmp=yes` hardening
on `kerf.service` is a non-issue — cleaner than `tzdata`, which would have needed autoupdate
disabled or a writable `data_dir` under `/opt/kerf/`. Cost is the same either way: tz-rule changes
land only when the dep is rebumped at deploy — acceptable for digest timestamps.

---

## 1. Contract read-back — COMPLETE (2026-07-02)

Done. Findings folded into the reconciliation note and §2/§3 below. Retained for the record:
projection in `digest_worker.ex` collapses to `%{name, category}`; render in
`telegram_formatter.ex`; metadata in `source_metadata` map; timestamp from `inserted_at`;
current truncation is silent slice-to-4096; existing per-category cap is 3 names + `+N more`.

---

## 2. Design (reconciled)

Render `transactional` as an itemised block; every other category unchanged (3-name + `+N more`
count lines).

Projection (`digest_worker.ex`), transactional only — carry three extra fields:

```
sender    = source_metadata["sender_name"] || source_metadata["sender"]
subject   = source_metadata["subject"]     || title
timestamp = %DateTime{} from RoutingDecision.inserted_at   (UTC)
```

Non-transactional projection stays `%{name, category}`, untouched.

Render (`telegram_formatter.ex`):

```
📑 Transactional (7)
  • 09:14  mijndomein.nl — Factuur 2026-07 beschikbaar
  • 08:02  bol.com — Je bestelling is verzonden
  • …
```

- **Line:** `HH:MM` in `config :kerf, :digest, display_tz` (default `Europe/Amsterdam`), converted
  from the UTC `timestamp` · sender (truncate ~30) · subject (truncate ~50, ellipsis).
- **Ordering:** newest-first (where a just-missed item is most likely to sit).
- **Cap:** `transactional_inline_cap` (default 40). Over cap → first 40 item lines, then
  `  … +M more`. This **overrides** the 3-name cap for transactional; all other categories keep
  3-name + `+N more`.
- **Empty:** on an otherwise-sent digest, zero transactional → `📑 Transactional: none`
  (absence is information). A **fully empty** digest stays nil/skipped — no "none"-only message.
- **Over-limit guard (replaces silent slice-to-4096):** if the assembled string would exceed the
  Telegram limit despite the cap, drop further transactional lines and end with `  … +M more`;
  never cut mid-line, never silently truncate the tail of the message. Implemented in
  `assemble_digest/5`: render at the cap, then decrement the shown count until the whole message
  fits `@telegram_limit`.
- **Footer on overflow (RESOLVED 2026-07-02, as shipped in GREEN):** §2's "the `+M more` note
  alone is the honest signal until item L exists" was ambiguous between *overflow-only* and
  *always*. Resolution: the `/digest_full` footer is present normally, and **dropped only when the
  transactional list overflows**, so the message ends on `… +M more`. Rationale: a message that
  both says `+M more` *and* advertises `/digest_full` — a command that doesn't exist yet (item L)
  — would be doubly misleading. This matches RED case (k) (`+M more` is the last line on
  overflow). If the footer should ever be *always* shown, that is a spec change: amend this bullet
  **and** case (k) together in a RED commit — never a GREEN-phase test edit.

---

## 3. RED (single pair, two modules — deterministic, seed-stable)

Write from §2 as reconciled. Minimal raising skeletons for any new function so the suite
compiles and fails on assertions, not on compile. Run twice — identical output.

**`digest_worker` (projection):**
- (a) transactional `RoutingDecision` with `source_metadata {subject, sender_name, sender}` +
  known `inserted_at` → projected item carries sender (name-preferred), subject, timestamp.
- (b) subject falls back to `title` when `source_metadata["subject"]` absent.
- (c) sender falls back to `source_metadata["sender"]` when `sender_name` absent.
- (d) non-transactional decision → projected `%{name, category}`, unchanged.

**`telegram_formatter` (render):**
- (e) K transactional items → one line each with sender + subject + `HH:MM`; assert local tz
  (`07:14Z → "09:14"`).
- (f) other categories still render 3-name + `+N more` count lines (unchanged).
- (g) `40+E` transactional → exactly 40 item lines + `+E more`.
- (h) newest-first ordering.
- (i) zero transactional on an otherwise-non-empty digest → `Transactional: none`.
- (j) fully empty digest → nil/skipped, no "none" line.
- (k) over-limit input → output ≤ Telegram limit, ends with `+M more`, no mid-line cut.
- (l) config fallback: with `:kerf, :digest` unset (`Application.get_env` → `nil`), the formatter
  still renders using defaults (`display_tz` "Europe/Amsterdam", cap 40) and does not raise —
  guards the exact prod `nil` state until the config lands with the GREEN deploy.

RED committed alone. No implementation. Report full red output + anything touched beyond scope.

## 4. GREEN

Extend the transactional projection in `digest_worker.ex`; extend the renderer + add tz
conversion + cap + over-limit guard in `telegram_formatter.ex`. No test edits. Separate commit
from RED, single concern ("itemise transactional in digest").

## 5. Verify (post-GREEN, before deploy)

- Full `digest_worker` + `telegram_formatter` suites green in Postgres env.
- Render a sample digest from real recent data (read-only): every transactional itemised, others
  counted, cap + `+M more`, tz correct, length within limit.
- Post-deploy: next real digest lists transactionals; today's mijndomein.nl class of mail appears
  by name.

## 6. Data-contract / caution notes

- **No migration.** Per-email data already lives on `RoutingDecision` + `source_metadata`; this
  is projection + render only. Nothing to `mix ecto.gen.migration`.
- Read `source_metadata` as a **map**, never as columns (§1 finding). Confirm no N+1 at
  projection time — preload the decisions' source data in one query if needed.
- Don't rename existing digest-state keys or the other categories' count-line format — additive
  only (data-contract rule).
- New config lives under `:kerf, :digest` + the `:elixir` `:time_zone_database` key in §0 — all
  additive. `:tz` was already a dep; no new dependency introduced.

---

## 7. Relationship to the other two symptoms

This resolves the *visibility* half of the "mijndomein.nl miss." The *interrupt* half — mail
important enough to ping rather than digest — is the `known_priority` sender marking (deferred
item N, a `kerf_prod` data change, git-invisible). Per sender: itemised-in-digest is enough for
routine transactional (invoices, shipping); `known_priority` for anything you must not miss
in-the-moment (e.g. domain expiry). Not this spec's scope, but the natural next lever.
