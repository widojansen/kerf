defmodule Kerf.Agents.EmailTriage.RouterTest do
  use Kerf.DataCase
  use Oban.Testing, repo: Kerf.Repo

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.{Router, RoutingDecision, RoutingConfig, TriageRecord}
  alias Kerf.KnowledgeBase.Document

  # ---------- fixtures ----------

  defp insert_email_doc!(overrides \\ %{}) do
    base = %{
      source_type: "email",
      source_id: "msg_#{System.unique_integer([:positive])}",
      title: "Test Subject",
      raw_text: "Body.",
      source_metadata: %{
        "sender" => "alice@example.com",
        "sender_name" => "Alice",
        "subject" => "Test Subject",
        "labels" => ["INBOX"]
      }
    }

    {:ok, doc} =
      %Document{}
      |> Document.changeset(Map.merge(base, overrides))
      |> Repo.insert()

    doc
  end

  defp insert_classified_triage!(doc, overrides \\ %{}) do
    base = %{
      document_id: doc.id,
      category: "business",
      sender_type: "known_priority",
      classifier_source: "fast_classifier",
      confidence: 1.0
    }

    {:ok, triage} =
      %TriageRecord{}
      |> TriageRecord.classify_changeset(Map.merge(base, overrides))
      |> Repo.insert()

    triage
  end

  defp insert_enriched_triage!(doc, classify_overrides \\ %{}, enrich_overrides \\ %{}) do
    classified = insert_classified_triage!(doc, classify_overrides)

    enrich_attrs =
      Map.merge(
        %{
          urgency: "low",
          action: "fyi",
          topic: ["kerf"],
          summary: "test summary",
          enrichment_version: 1
        },
        enrich_overrides
      )

    {:ok, enriched} =
      classified
      |> TriageRecord.enrich_changeset(enrich_attrs)
      |> Repo.update()

    enriched
  end

  # Builds an isolated RoutingConfig instance with a fixture config file in a
  # per-test temp dir. Returns the GenServer name. Cleaned up via on_exit.
  defp start_routing_config_with_rules!(rules, version \\ "test-v1") do
    tmp_dir = Path.join(System.tmp_dir!(), "kerf_router_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    default_path = Path.join(tmp_dir, "default.exs")
    override_path = Path.join(tmp_dir, "override.exs")

    config_content = """
    %{
      version: #{inspect(version)},
      rules: #{inspect(rules, limit: :infinity, printable_limit: :infinity)}
    }
    """

    File.write!(default_path, config_content)

    name = :"router_test_rc_#{System.unique_integer([:positive])}"
    {:ok, _pid} = RoutingConfig.start_link(
      name: name,
      default_path: default_path,
      override_path: override_path
    )
    _ = RoutingConfig.current(name)
    # macOS fsevents warmup (matches RoutingConfig test pattern).
    Process.sleep(150)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    name
  end

  defp set_routing_config_name(name) do
    previous = Application.get_env(:kerf, Kerf.Agents.EmailTriage.Router, [])

    Application.put_env(
      :kerf,
      Kerf.Agents.EmailTriage.Router,
      Keyword.put(previous, :routing_config_name, name)
    )

    on_exit(fn -> Application.put_env(:kerf, Kerf.Agents.EmailTriage.Router, previous) end)
  end

  # ---------- RoutingDecision schema ----------

  describe "RoutingDecision schema" do
    test "persists and reloads a row with all fields" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc)

      attrs = %{
        email_triage_id: triage.id,
        rule_name: "priority_high_urgency",
        action_taken: "telegram_ping",
        routing_config_version: "2026-05-11.1"
      }

      {:ok, inserted} =
        %RoutingDecision{}
        |> RoutingDecision.changeset(attrs)
        |> Repo.insert()

      reloaded = Repo.get!(RoutingDecision, inserted.id)
      assert reloaded.email_triage_id == triage.id
      assert reloaded.rule_name == "priority_high_urgency"
      assert reloaded.action_taken == "telegram_ping"
      assert reloaded.routing_config_version == "2026-05-11.1"
      assert %DateTime{} = reloaded.inserted_at
    end

    test "FK to email_triage is enforced" do
      ghost_id = Ecto.UUID.generate()

      attrs = %{
        email_triage_id: ghost_id,
        rule_name: "x",
        action_taken: "silent",
        routing_config_version: "v"
      }

      {:error, changeset} =
        %RoutingDecision{}
        |> RoutingDecision.changeset(attrs)
        |> Repo.insert()

      refute changeset.valid?
      assert %{email_triage_id: [msg | _]} = errors_on(changeset)
      assert msg =~ "does not exist"
    end

    test "action_taken values are validated (one of telegram_ping | telegram_digest | silent)" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc)

      attrs = %{
        email_triage_id: triage.id,
        rule_name: "bogus_action_rule",
        action_taken: "totally_invented_action",
        routing_config_version: "v"
      }

      cs = RoutingDecision.changeset(%RoutingDecision{}, attrs)
      refute cs.valid?
      assert %{action_taken: [_msg | _]} = errors_on(cs)
    end
  end

  # ---------- matcher logic (direct + tuple matchers) ----------

  describe "rule matching" do
    test "direct-value match: category: 'security' matches a record with category: 'security'" do
      assert Router.matches?(%{category: "security", urgency: "high"}, %{category: "security"})
    end

    test "direct-value mismatch returns no match" do
      refute Router.matches?(%{category: "newsletter"}, %{category: "security"})
    end

    test "{:contains, value} matches when value is in the record's array field" do
      assert Router.matches?(%{topic: ["kerf", "legal"]}, %{topic: {:contains, "kerf"}})
    end

    test "{:contains, value} doesn't match when value is absent" do
      refute Router.matches?(%{topic: ["legal", "financial"]}, %{topic: {:contains, "kerf"}})
    end

    test "empty match %{} always matches" do
      assert Router.matches?(%{category: "anything", urgency: "low"}, %{})
    end
  end

  # ---------- worker logic ----------

  describe "perform/1 worker pipeline" do
    # These tests pre-date Step 12 and don't assert on Telegram delivery.
    # Step 12's default telegram_sender returns {:error, :no_token} when no
    # token is configured (test env), which would cause :telegram_ping rules
    # to fail. Install a noop sender so these tests focus on rule selection
    # + decision-row writes only.
    setup do
      previous = Application.get_env(:kerf, Router, [])

      Application.put_env(
        :kerf,
        Router,
        Keyword.put(previous, :telegram_sender, fn _chat_id, _text -> :ok end)
      )

      on_exit(fn -> Application.put_env(:kerf, Router, previous) end)
      :ok
    end

    test "enriched TriageRecord + matching rule → inserts decision row with rule_name, action_taken, routing_config_version" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{}, %{urgency: "high"})  # sender_type known_priority + urgency high

      rules = [
        %{name: "priority_high_urgency", match: %{sender_type: "known_priority", urgency: "high"}, action: :telegram_ping},
        %{name: "default_silent", match: %{}, action: :silent}
      ]

      rc_name = start_routing_config_with_rules!(rules, "step9-v1")
      set_routing_config_name(rc_name)

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      [decision] =
        from(d in RoutingDecision, where: d.email_triage_id == ^triage.id)
        |> Repo.all()

      assert decision.rule_name == "priority_high_urgency"
      assert decision.action_taken == "telegram_ping"
      assert decision.routing_config_version == "step9-v1"
    end

    test "walks rules in order; first match wins (even if later rules would also match)" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{category: "security"}, %{urgency: "high"})

      rules = [
        %{name: "first_match", match: %{category: "security"}, action: :telegram_ping},
        %{name: "would_also_match_but_later", match: %{urgency: "high"}, action: :telegram_digest},
        %{name: "default_silent", match: %{}, action: :silent}
      ]

      rc_name = start_routing_config_with_rules!(rules)
      set_routing_config_name(rc_name)

      :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      [decision] = Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^triage.id)
      assert decision.rule_name == "first_match"
      assert decision.action_taken == "telegram_ping"
    end

    test "no matching rule → records action_taken 'silent' (defensive — shouldn't happen with default_silent in priv)" do
      # Pins defensive behavior: if someone removes the catch-all default_silent
      # from the override, the Router must NOT crash. Logs a warning and records
      # :silent — fail safe, not crash.
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{category: "newsletter"}, %{urgency: "low"})

      rules = [
        %{name: "priority_only", match: %{sender_type: "known_priority", urgency: "high"}, action: :telegram_ping}
        # Note: no catch-all default_silent — simulates operator accidentally removing it.
      ]

      rc_name = start_routing_config_with_rules!(rules)
      set_routing_config_name(rc_name)

      :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      [decision] = Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^triage.id)
      assert decision.action_taken == "silent"
      assert decision.rule_name == "no_match_fallback"
    end

    test "non-enriched TriageRecord (classified / pending / unclassifiable) → no-op :ok, no decision row" do
      doc = insert_email_doc!()
      classified = insert_classified_triage!(doc)

      rules = [%{name: "default_silent", match: %{}, action: :silent}]
      rc_name = start_routing_config_with_rules!(rules)
      set_routing_config_name(rc_name)

      assert :ok = perform_job(Router, %{"triage_record_id" => classified.id})

      assert Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^classified.id) == []
    end

    test "non-existent TriageRecord id → {:error, :not_found}" do
      ghost_id = Ecto.UUID.generate()

      rules = [%{name: "default_silent", match: %{}, action: :silent}]
      rc_name = start_routing_config_with_rules!(rules)
      set_routing_config_name(rc_name)

      assert {:error, :not_found} = perform_job(Router, %{"triage_record_id" => ghost_id})
    end

    test "routing_config_version in the decision row matches RoutingConfig.current().version at the moment of decision (pinned-at-start)" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{}, %{urgency: "high"})

      rules = [
        %{name: "priority_high_urgency", match: %{sender_type: "known_priority", urgency: "high"}, action: :telegram_ping}
      ]

      rc_name = start_routing_config_with_rules!(rules, "v-pinned-at-start")
      set_routing_config_name(rc_name)

      # Single RoutingConfig.current/0 read at the start of perform/1: the
      # decision row records that snapshot's version. Mid-job reloads do not
      # affect the in-flight job.
      :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      [decision] = Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^triage.id)
      assert decision.routing_config_version == "v-pinned-at-start"
    end
  end

  describe "perform/1 Telegram delivery (Step 12)" do
    # Inject the telegram_sender via Application config — same pattern as
    # Enricher's enrich_fn seam. Tests own the lifecycle via put_config/on_exit.
    defp set_telegram_sender(fun) do
      previous = Application.get_env(:kerf, Router, [])

      Application.put_env(
        :kerf,
        Router,
        Keyword.put(previous, :telegram_sender, fun)
      )

      on_exit(fn -> Application.put_env(:kerf, Router, previous) end)
    end

    test ":telegram_ping action calls telegram_sender with formatted ping; decision row inserted" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{}, %{urgency: "high", summary: "Important!"})

      rules = [
        %{name: "priority_ping", match: %{sender_type: "known_priority"}, action: :telegram_ping}
      ]

      rc_name = start_routing_config_with_rules!(rules, "step12-ping")
      set_routing_config_name(rc_name)

      test_pid = self()
      set_telegram_sender(fn chat_id, text ->
        send(test_pid, {:telegram_sent, chat_id, text})
        :ok
      end)

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      # Sender called with the formatted ping
      assert_receive {:telegram_sent, _chat_id, text}
      assert is_binary(text)
      assert text =~ "Important!"

      # Decision row still inserted (Step 9 invariant preserved)
      [decision] = Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^triage.id)
      assert decision.action_taken == "telegram_ping"
      assert decision.rule_name == "priority_ping"
    end

    test ":telegram_digest action does NOT call telegram_sender; decision row still inserted" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{category: "business"}, %{urgency: "medium"})

      rules = [
        %{name: "business_medium_digest", match: %{category: "business", urgency: "medium"}, action: :telegram_digest}
      ]

      rc_name = start_routing_config_with_rules!(rules, "step12-digest")
      set_routing_config_name(rc_name)

      set_telegram_sender(fn _chat_id, _text ->
        flunk(":telegram_digest must not invoke the Telegram sender at Step 12 (Step 13's cron handles digest delivery)")
      end)

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      [decision] = Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^triage.id)
      assert decision.action_taken == "telegram_digest"
    end

    test ":silent action does NOT call telegram_sender; decision row still inserted" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{category: "newsletter"}, %{urgency: "low"})

      rules = [%{name: "default_silent", match: %{}, action: :silent}]

      rc_name = start_routing_config_with_rules!(rules, "step12-silent")
      set_routing_config_name(rc_name)

      set_telegram_sender(fn _chat_id, _text ->
        flunk(":silent must not invoke the Telegram sender")
      end)

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      [decision] = Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^triage.id)
      assert decision.action_taken == "silent"
    end

    test "telegram_sender returning {:error, _} causes perform/1 to return {:error, _} (Oban retries)" do
      doc = insert_email_doc!()
      triage = insert_enriched_triage!(doc, %{}, %{urgency: "high"})

      rules = [
        %{name: "priority_ping", match: %{sender_type: "known_priority"}, action: :telegram_ping}
      ]

      rc_name = start_routing_config_with_rules!(rules, "step12-error")
      set_routing_config_name(rc_name)

      set_telegram_sender(fn _chat_id, _text -> {:error, "HTTP 500"} end)

      assert {:error, _reason} = perform_job(Router, %{"triage_record_id" => triage.id})
    end
  end

  # ---------- helpers ----------

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
