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
