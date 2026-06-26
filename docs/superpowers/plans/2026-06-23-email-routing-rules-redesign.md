# Email Routing Rules Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the email routing policy so important mail (invoices, personal, business-to-me) pings Telegram, bulk mail (newsletters and the like) digests, and only spam is silenced.

**Architecture:** Pure policy change to the data file `priv/email_routing.exs`, evaluated by the existing `Kerf.Agents.EmailTriage.Router` (first-matching-rule-wins over `category`/`sender_type`/`urgency`/`action`/`topic`). No Elixir source, schema, or migration changes. Verified by a new deterministic, DB-free policy test that loads the real rules file and asserts the resolved action for representative records.

**Tech Stack:** Elixir, ExUnit. The Router matcher supports equality and `{:contains, item}` on list fields (confirmed `router.ex:64-69`); valid actions are `[:telegram_ping, :telegram_digest, :silent]` (confirmed `routing_config.ex:30`).

**Design doc:** `docs/superpowers/specs/2026-06-22-email-routing-rules-redesign-design.md`

---

## Important environment note

`mix test` is aliased to `ecto.create`/`ecto.migrate`, and Postgres is not available locally (it runs on the `spark` host). The policy test in this plan is **pure and DB-free**, so run it WITHOUT booting the app, using:

```bash
MIX_ENV=test mix run --no-start -e 'ExUnit.start(autorun: false); Code.require_file("test/agents/email_triage/email_routing_rules_test.exs"); ExUnit.run()'
```

Do NOT use `mix test` for this file — it will fail trying to create the database. The existing DB-backed suites (`router_test.exs`, `enricher_test.exs`) are unaffected by this change and should be run by the user in the DB-enabled environment as a final check.

---

## File Structure

- **Modify:** `priv/email_routing.exs` — the routing rule set (data). The single behavioural change.
- **Create:** `test/agents/email_triage/email_routing_rules_test.exs` — DB-free policy test that loads `priv/email_routing.exs` and asserts resolved actions. Owns: "do the shipped rules route representative emails correctly."

No other files change. `Router`, `RoutingConfig`, the enricher, classifier, and schema are untouched.

---

## Task 1: Policy test (RED)

**Files:**
- Create: `test/agents/email_triage/email_routing_rules_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/agents/email_triage/email_routing_rules_test.exs` with exactly this content:

```elixir
defmodule Kerf.Agents.EmailTriage.EmailRoutingRulesTest do
  # DB-free policy test: loads the SHIPPED priv/email_routing.exs and asserts the
  # resolved routing action for representative emails. Resolution mirrors the
  # Router: first rule whose match spec matches wins (Router.matches?/2 is the
  # real predicate; record shape matches Router.record_to_map/1's atom-keyed map).
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.Router

  @valid_actions [:telegram_ping, :telegram_digest, :silent]

  setup_all do
    {config, _bindings} = Code.eval_file("priv/email_routing.exs")
    %{config: config}
  end

  # A record as projected by Router.record_to_map/1. Defaults are inert; each
  # test overrides only the fields that matter. topic is always a list.
  defp record(overrides) do
    Map.merge(
      %{
        category: "newsletter",
        sender_type: "known_routine",
        urgency: "none",
        action: "fyi",
        topic: []
      },
      Map.new(overrides)
    )
  end

  # First-match-wins resolution, exactly as Router.pick_rule/2 does it.
  defp resolve(record, rules) do
    case Enum.find(rules, fn rule -> Router.matches?(record, rule.match) end) do
      nil -> {:no_match, nil}
      rule -> {rule.name, rule.action}
    end
  end

  describe "shipped routing policy (priv/email_routing.exs)" do
    test "spam is silenced before any ping rule", %{config: config} do
      rec = record(category: "spam", action: "pay", topic: ["financial"])
      assert {"spam_silent", :silent} = resolve(rec, config.rules)
    end

    test "personal mail pings", %{config: config} do
      rec = record(category: "personal", urgency: "low", action: "reply_needed", topic: ["family"])
      assert {"personal_ping", :telegram_ping} = resolve(rec, config.rules)
    end

    test "a bill to pay pings (invoice_to_pay)", %{config: config} do
      rec = record(category: "transactional", action: "pay", sender_type: "automated_system", urgency: "low")
      assert {"invoice_to_pay", :telegram_ping} = resolve(rec, config.rules)
    end

    test "business financial (receipt/invoice) pings", %{config: config} do
      rec = record(category: "business", action: "file", topic: ["financial"], urgency: "none")
      assert {"business_financial", :telegram_ping} = resolve(rec, config.rules)
    end

    test "transactional financial pings", %{config: config} do
      rec = record(category: "transactional", action: "file", topic: ["financial"], sender_type: "automated_system")
      assert {"transactional_financial", :telegram_ping} = resolve(rec, config.rules)
    end

    test "business awaiting a reply pings", %{config: config} do
      rec = record(category: "business", action: "reply_needed", urgency: "low", topic: ["agency_partner"])
      assert {"business_reply_needed", :telegram_ping} = resolve(rec, config.rules)
    end

    test "high-urgency business pings (the Datadog alert case)", %{config: config} do
      rec = record(category: "business", urgency: "high", action: "review", sender_type: "known_routine", topic: ["automotive"])
      assert {"business_high", :telegram_ping} = resolve(rec, config.rules)
    end

    test "medium-urgency business pings", %{config: config} do
      rec = record(category: "business", urgency: "medium", action: "review", topic: ["infrastructure"])
      assert {"business_medium", :telegram_ping} = resolve(rec, config.rules)
    end

    test "cold low-urgency business digests (not a ping)", %{config: config} do
      rec = record(category: "business", sender_type: "unknown_human", urgency: "low", action: "schedule", topic: ["infrastructure"])
      assert {"default_digest", :telegram_digest} = resolve(rec, config.rules)
    end

    test "a kerf-tagged newsletter digests (no longer pings)", %{config: config} do
      rec = record(category: "newsletter", topic: ["kerf", "financial"], action: "fyi", urgency: "none")
      assert {"default_digest", :telegram_digest} = resolve(rec, config.rules)
    end

    test "non-financial transactional digests", %{config: config} do
      rec = record(category: "transactional", action: "fyi", topic: ["infrastructure"], sender_type: "automated_system", urgency: "low")
      assert {"default_digest", :telegram_digest} = resolve(rec, config.rules)
    end
  end

  describe "config validity" do
    test "version is the redesigned policy version", %{config: config} do
      assert config.version == "2026-06-22.1"
    end

    test "all actions are valid and rule names are unique", %{config: config} do
      assert Enum.all?(config.rules, &(&1.action in @valid_actions))
      names = Enum.map(config.rules, & &1.name)
      assert names == Enum.uniq(names)
    end

    test "the final rule is the catch-all digest default", %{config: config} do
      last = List.last(config.rules)
      assert last.match == %{}
      assert last.name == "default_digest"
      assert last.action == :telegram_digest
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it FAILS against the current rules**

Run:
```bash
MIX_ENV=test mix run --no-start -e 'ExUnit.start(autorun: false); Code.require_file("test/agents/email_triage/email_routing_rules_test.exs"); ExUnit.run()'
```
Expected: multiple failures. Against the current `priv/email_routing.exs` (`version: "2026-05-11.1"`), e.g. "personal mail pings" fails (personal currently falls through to `default_silent` → `:silent`), "high-urgency business pings" fails (→ `:silent`), "a kerf-tagged newsletter digests" fails (currently `kerf_topic_anything` → `:telegram_ping`), and the version/`default_digest` checks fail. This proves the test exercises the policy.

- [ ] **Step 3: Commit the RED test**

```bash
git add test/agents/email_triage/email_routing_rules_test.exs
git commit -m "test: RED policy test for redesigned email routing rules

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Rewrite the routing policy (GREEN)

**Files:**
- Modify: `priv/email_routing.exs` (full rewrite)

- [ ] **Step 1: Replace `priv/email_routing.exs` with the new rule set**

Overwrite the entire file with exactly this content:

```elixir
%{
  version: "2026-06-22.1",
  rules: [
    # Silence spam FIRST — before any ping rule — so a spam "invoice" (a scam
    # with action: "pay") can never trip invoice_to_pay below.
    %{
      name: "spam_silent",
      match: %{category: "spam"},
      action: :silent
    },

    # Private messages to the user.
    %{
      name: "personal_ping",
      match: %{category: "personal"},
      action: :telegram_ping
    },

    # Bills needing payment, any category (spam already excluded above).
    %{
      name: "invoice_to_pay",
      match: %{action: "pay"},
      action: :telegram_ping
    },

    # Business invoices / receipts / financial mail.
    %{
      name: "business_financial",
      match: %{category: "business", topic: {:contains, "financial"}},
      action: :telegram_ping
    },

    # Invoices / receipts that arrive classified as transactional.
    %{
      name: "transactional_financial",
      match: %{category: "transactional", topic: {:contains, "financial"}},
      action: :telegram_ping
    },

    # Business awaiting a reply from the user.
    %{
      name: "business_reply_needed",
      match: %{category: "business", action: "reply_needed"},
      action: :telegram_ping
    },

    # Time-sensitive business (e.g. the Datadog production alert).
    %{
      name: "business_high",
      match: %{category: "business", urgency: "high"},
      action: :telegram_ping
    },

    # Moderately time-sensitive business.
    %{
      name: "business_medium",
      match: %{category: "business", urgency: "medium"},
      action: :telegram_ping
    },

    # Catch-all: everything else (newsletters, marketing, social, non-financial
    # transactional, low-urgency/cold business) is batched into the digest.
    %{
      name: "default_digest",
      match: %{},
      action: :telegram_digest
    }
  ]
}
```

- [ ] **Step 2: Run the policy test to verify it PASSES**

Run:
```bash
MIX_ENV=test mix run --no-start -e 'ExUnit.start(autorun: false); Code.require_file("test/agents/email_triage/email_routing_rules_test.exs"); ExUnit.run()'
```
Expected: `Result: 14 passed` (11 policy + 3 validity), no failures.

- [ ] **Step 3: Verify the project still compiles**

Run:
```bash
MIX_ENV=test mix compile 2>&1 | grep -i 'email_routing\|routing_config\|router.ex' || echo "no routing-related compile errors"
```
Expected: `no routing-related compile errors` (the `.exs` is data, not compiled into the app; `RoutingConfig` evaluates it at runtime).

- [ ] **Step 4: Commit the GREEN policy change**

```bash
git add priv/email_routing.exs
git commit -m "feat: redesign email routing rules so important mail pings (symptom A)

Ping invoices/personal/business-to-me; digest newsletters and the like;
silence only spam. Drop the over-firing kerf_topic_anything (175 spurious
newsletter pings) and the dead security_alerts rule; flip the catch-all
default from silent to digest. Version 2026-06-22.1.

Implements docs/superpowers/specs/2026-06-22-email-routing-rules-redesign-design.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Final verification handoff

- [ ] **Step 1: Confirm no existing test pins the shipped rules**

This was verified during planning: `router_test.exs` and `routing_config_test.exs` use inline rule fixtures and an injected `wiring-test-v1` config, not the real `priv/email_routing.exs`. No test update is required. (If `grep -rn '2026-05-11.1\|kerf_topic_anything' test/` returns only `RoutingDecision`-schema literal strings, nothing is broken.)

Run:
```bash
grep -rn 'kerf_topic_anything\|security_alerts' test/ || echo "no test references the removed rule names"
```
Expected: `no test references the removed rule names`.

- [ ] **Step 2: Hand off DB-backed verification to the user**

The DB-backed suites can only run where Postgres is available (the `spark`). Ask the user to run, in the DB-enabled environment:
```bash
mix test test/agents/email_triage/router_test.exs test/agents/email_triage/routing_config_test.exs test/agents/email_triage/digest_worker_test.exs
```
Expected: green — these are unaffected by the policy change. This is a confirmation step, not a blocker for the commits above.

---

## Self-Review

**Spec coverage:** §4 rule table → Task 2 (all 9 rules, verbatim, same order/names/actions). §2 non-goals (no topic fix, no priority-path revival, no recipient signal) → respected; only the data file and a test change. §5 audit cases → Task 1 covers Datadog (business_high), Anthropic receipt (business_financial), cold business (default_digest), kerf newsletter (default_digest), personal (personal_ping), spam (spam_silent). §6 tunables (rule 8) → present as `business_medium` with its own test so it can be dropped later by removing one rule + one test. §7 testing approach → Task 1 (Code.eval_file + Router.matches?). §8 reversibility → no code change; restoring the file rolls back.

**Placeholder scan:** none — full test code and full file content inlined.

**Type/name consistency:** rule names in Task 1 assertions (`spam_silent`, `personal_ping`, `invoice_to_pay`, `business_financial`, `transactional_financial`, `business_reply_needed`, `business_high`, `business_medium`, `default_digest`) match Task 2's file exactly. Version string `2026-06-22.1` matches in both. Actions are atoms from `@valid_actions`.
