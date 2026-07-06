defmodule Kerf.Agents.EmailTriage.NotifyGuardRouterTest do
  @moduledoc """
  Cycle 2 (SPEC C Router addendum): the NotifyGuard silence override applied at
  the Router emission seam (`handle_record` → decision row + deliver).

  The guard silences self-sent (`"SENT"` label) and stale (older than MAX_AGE)
  mail by overriding the routed `action_atom` to `:silent` *before* the decision
  row is written — so both the immediate `deliver` and the downstream
  `DigestWorker` cron (`WHERE action_taken="telegram_digest"`) stay silent.
  """
  # async: false — mutates the shared `:kerf, Router` app env (telegram_sender,
  # now_fn, routing_config_name).
  use Kerf.DataCase, async: false
  use Oban.Testing, repo: Kerf.Repo

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.{Router, RoutingConfig, RoutingDecision, TriageRecord}
  alias Kerf.KnowledgeBase.Document

  # Fixed clock shared with Cycle 1; every fixture date derives from it via at/1.
  @now ~U[2026-04-01 12:00:00Z]

  # RFC2822 rendering of @now shifted back `hours` (weekday omitted — advisory).
  defp at(hours) do
    @now
    |> DateTime.add(-hours * 3600, :second)
    |> Calendar.strftime("%d %b %Y %H:%M:%S +0000")
  end

  # ---------- fixtures (mirror router_test.exs) ----------

  defp insert_email_doc!(metadata_overrides) do
    base_metadata = %{
      "sender" => "alice@example.com",
      "sender_name" => "Alice",
      "subject" => "Test Subject",
      "labels" => ["INBOX"]
    }

    attrs = %{
      source_type: "email",
      source_id: "msg_#{System.unique_integer([:positive])}",
      title: "Test Subject",
      raw_text: "Body.",
      source_metadata: Map.merge(base_metadata, metadata_overrides)
    }

    {:ok, doc} =
      %Document{}
      |> Document.changeset(attrs)
      |> Repo.insert()

    doc
  end

  defp insert_enriched_triage!(doc) do
    {:ok, classified} =
      %TriageRecord{}
      |> TriageRecord.classify_changeset(%{
        document_id: doc.id,
        category: "business",
        sender_type: "known_priority",
        classifier_source: "fast_classifier",
        confidence: 1.0
      })
      |> Repo.insert()

    {:ok, enriched} =
      classified
      |> TriageRecord.enrich_changeset(%{
        urgency: "high",
        action: "fyi",
        topic: ["kerf"],
        summary: "test summary",
        enrichment_version: 1
      })
      |> Repo.update()

    enriched
  end

  defp start_routing_config_with_rules!(rules, version \\ "cycle2-v1") do
    tmp_dir =
      Path.join(System.tmp_dir!(), "kerf_ng_router_#{System.unique_integer([:positive])}")

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

    name = :"ng_router_rc_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      RoutingConfig.start_link(name: name, default_path: default_path, override_path: override_path)

    _ = RoutingConfig.current(name)
    Process.sleep(150)

    on_exit(fn -> File.rm_rf(tmp_dir) end)
    name
  end

  # Merge keys into the shared :kerf, Router env and restore on exit. Sets the
  # telegram_sender spy, the deterministic now_fn, and the isolated
  # routing_config_name in one shot.
  defp put_router_env(kvs) do
    previous = Application.get_env(:kerf, Router, [])
    Application.put_env(:kerf, Router, Keyword.merge(previous, kvs))
    on_exit(fn -> Application.put_env(:kerf, Router, previous) end)
  end

  defp spy_sender do
    test_pid = self()

    fn chat_id, text ->
      send(test_pid, {:telegram_sent, chat_id, text})
      :ok
    end
  end

  defp setup_router(rules, doc_metadata) do
    doc = insert_email_doc!(doc_metadata)
    triage = insert_enriched_triage!(doc)
    rc_name = start_routing_config_with_rules!(rules)

    put_router_env(
      telegram_sender: spy_sender(),
      now_fn: fn -> @now end,
      routing_config_name: rc_name
    )

    triage
  end

  defp decision_for(triage_id) do
    Repo.one(from d in RoutingDecision, where: d.email_triage_id == ^triage_id)
  end

  @ping_all [%{name: "ping_all", match: %{}, action: :telegram_ping}]
  @digest_all [%{name: "digest_all", match: %{}, action: :telegram_digest}]
  @silent_all [%{name: "silent_all", match: %{}, action: :silent}]

  # ---------- the guard at the Router seam ----------

  describe "NotifyGuard override in Router.handle_record/1" do
    test "sent_label_silenced — SENT-labelled mail with a ping rule is silenced" do
      triage = setup_router(@ping_all, %{"labels" => ["SENT", "INBOX"], "date" => at(1)})

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      assert decision_for(triage.id).action_taken == "silent"
      refute_receive {:telegram_sent, _chat_id, _text}
    end

    test "stale_silenced — 48h-old mail with a ping rule is silenced" do
      triage = setup_router(@ping_all, %{"labels" => ["INBOX"], "date" => at(48)})

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      assert decision_for(triage.id).action_taken == "silent"
      refute_receive {:telegram_sent, _chat_id, _text}
    end

    test "recent_inbox_pings — recent inbox mail with a ping rule still pings" do
      triage = setup_router(@ping_all, %{"labels" => ["INBOX"], "date" => at(1)})

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      assert decision_for(triage.id).action_taken == "telegram_ping"
      assert_receive {:telegram_sent, _chat_id, text}
      assert text =~ "test summary"
    end

    test "guard_only_silences — a :silent rule stays silent (guard never un-silences)" do
      triage = setup_router(@silent_all, %{"labels" => ["INBOX"], "date" => at(1)})

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      assert decision_for(triage.id).action_taken == "silent"
      refute_receive {:telegram_sent, _chat_id, _text}
    end

    test "silenced_excluded_from_digest — guard-silenced mail is not recorded as telegram_digest" do
      triage = setup_router(@digest_all, %{"labels" => ["SENT"], "date" => at(1)})

      assert :ok = perform_job(Router, %{"triage_record_id" => triage.id})

      assert decision_for(triage.id).action_taken == "silent"
    end
  end
end
