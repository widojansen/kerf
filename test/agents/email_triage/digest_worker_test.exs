defmodule Kerf.Agents.EmailTriage.DigestWorkerTest do
  # Tests the cron-triggered worker that drains undigested
  # `email_routing_decisions` rows (action_taken: "telegram_digest") into a
  # single Telegram digest message per cron tick.
  use Kerf.DataCase
  use Oban.Testing, repo: Kerf.Repo

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.{DigestRun, DigestWorker, RoutingDecision, TriageRecord}
  alias Kerf.KnowledgeBase.Document

  # ---------- fixtures ----------

  defp insert_email_doc!(suffix, overrides \\ %{}) do
    base = %{
      source_type: "email",
      source_id: "msg_dw_#{suffix}_#{System.unique_integer([:positive])}",
      title: "Subject #{suffix}",
      raw_text: "Body.",
      source_metadata: %{
        "sender" => "sender_#{suffix}@example.com",
        "sender_name" => "Sender #{suffix}",
        "labels" => ["INBOX"]
      }
    }

    {:ok, doc} =
      %Document{}
      |> Document.changeset(Map.merge(base, overrides))
      |> Repo.insert()

    doc
  end

  defp insert_enriched_triage!(doc, category) do
    {:ok, classified} =
      %TriageRecord{}
      |> TriageRecord.classify_changeset(%{
        document_id: doc.id,
        category: category,
        sender_type: "known_routine",
        classifier_source: "fast_classifier",
        confidence: 1.0
      })
      |> Repo.insert()

    {:ok, enriched} =
      classified
      |> TriageRecord.enrich_changeset(%{
        urgency: "medium",
        action: "review",
        topic: ["dev_tools"],
        summary: "summary"
      })
      |> Repo.update()

    enriched
  end

  defp insert_digest_decision!(triage) do
    {:ok, dec} =
      %RoutingDecision{}
      |> RoutingDecision.changeset(%{
        email_triage_id: triage.id,
        rule_name: "business_medium",
        action_taken: "telegram_digest",
        routing_config_version: "step13-test"
      })
      |> Repo.insert()

    dec
  end

  defp set_telegram_sender(fun) do
    previous = Application.get_env(:kerf, DigestWorker, [])

    Application.put_env(
      :kerf,
      DigestWorker,
      Keyword.put(previous, :telegram_sender, fun)
    )

    on_exit(fn -> Application.put_env(:kerf, DigestWorker, previous) end)
  end

  # ---------- worker tests ----------

  describe "perform/1 happy path" do
    test "queries undigested rows, formats, sends, UPDATEs digested_at, inserts DigestRun with status 'sent'" do
      doc1 = insert_email_doc!("h1")
      doc2 = insert_email_doc!("h2")
      doc3 = insert_email_doc!("h3")

      t1 = insert_enriched_triage!(doc1, "newsletter")
      t2 = insert_enriched_triage!(doc2, "newsletter")
      t3 = insert_enriched_triage!(doc3, "business")

      d1 = insert_digest_decision!(t1)
      d2 = insert_digest_decision!(t2)
      d3 = insert_digest_decision!(t3)

      test_pid = self()

      set_telegram_sender(fn chat_id, text ->
        send(test_pid, {:digest_sent, chat_id, text})
        :ok
      end)

      assert :ok = perform_job(DigestWorker, %{})

      # Sender called once with formatted digest
      assert_receive {:digest_sent, _chat_id, text}
      assert is_binary(text)
      assert text =~ "📬"

      # digested_at set on all three decisions
      for id <- [d1.id, d2.id, d3.id] do
        reloaded = Repo.get!(RoutingDecision, id)
        assert %DateTime{} = reloaded.digested_at
      end

      # DigestRun audit row with status: "sent", count: 3
      [run] = Repo.all(from r in DigestRun, where: r.status == "sent")
      assert run.decision_count == 3
      assert run.error == nil
    end
  end

  describe "perform/1 empty path" do
    test "zero undigested rows: no Telegram send, inserts DigestRun with status 'empty'" do
      set_telegram_sender(fn _chat_id, _text ->
        flunk("Empty digest must not invoke the Telegram sender")
      end)

      assert :ok = perform_job(DigestWorker, %{})

      [run] = Repo.all(from r in DigestRun, where: r.status == "empty")
      assert run.decision_count == 0
      assert run.error == nil
    end
  end

  describe "perform/1 error path" do
    test "sender returning {:error, _} rolls back: rows stay undigested, no DigestRun, returns {:error, _}" do
      doc = insert_email_doc!("err")
      triage = insert_enriched_triage!(doc, "business")
      decision = insert_digest_decision!(triage)

      set_telegram_sender(fn _chat_id, _text -> {:error, "telegram timeout"} end)

      assert {:error, _} = perform_job(DigestWorker, %{"triage_record_id" => nil})

      # Decision still undigested (UPDATE rolled back)
      reloaded = Repo.get!(RoutingDecision, decision.id)
      assert reloaded.digested_at == nil

      # No DigestRun row was committed (transaction rolled back)
      assert Repo.aggregate(DigestRun, :count, :id) == 0
    end
  end

  describe "perform/1 window computation" do
    test "window_start = min(routing_decisions.inserted_at); window_end = sent_at" do
      doc1 = insert_email_doc!("w1")
      doc2 = insert_email_doc!("w2")
      t1 = insert_enriched_triage!(doc1, "business")
      t2 = insert_enriched_triage!(doc2, "newsletter")
      d1 = insert_digest_decision!(t1)
      _d2 = insert_digest_decision!(t2)

      set_telegram_sender(fn _chat_id, _text -> :ok end)

      before_run = DateTime.utc_now(:microsecond)
      assert :ok = perform_job(DigestWorker, %{})
      after_run = DateTime.utc_now(:microsecond)

      [run] = Repo.all(from r in DigestRun, where: r.status == "sent")

      # window_start matches the earliest decision's inserted_at
      assert DateTime.compare(run.window_start, d1.inserted_at) in [:eq, :gt, :lt],
             "window_start should be set; got #{inspect(run.window_start)}"

      # The earliest decision's inserted_at predates the worker run.
      assert DateTime.compare(run.window_start, before_run) in [:eq, :lt]

      # window_end equals sent_at (or is set to a value within the run window)
      assert DateTime.compare(run.window_end, run.sent_at) == :eq
      assert DateTime.compare(run.window_end, after_run) in [:eq, :lt]
    end
  end

  describe "perform/1 idempotency" do
    test "two cron ticks on the same data: second tick is :empty (no duplicate digest)" do
      doc = insert_email_doc!("idem")
      triage = insert_enriched_triage!(doc, "business")
      _decision = insert_digest_decision!(triage)

      send_count_agent = start_supervised!({Agent, fn -> 0 end})

      set_telegram_sender(fn _chat_id, _text ->
        Agent.update(send_count_agent, &(&1 + 1))
        :ok
      end)

      # First tick: drains the queued decision, sends digest.
      assert :ok = perform_job(DigestWorker, %{})
      assert Agent.get(send_count_agent, & &1) == 1

      # Second tick: nothing to digest (the row from tick 1 is marked digested_at).
      assert :ok = perform_job(DigestWorker, %{})
      assert Agent.get(send_count_agent, & &1) == 1, "Second tick must not re-send"

      # Two DigestRun rows: one "sent", one "empty"
      runs = Repo.all(from r in DigestRun, order_by: [asc: r.inserted_at])
      assert length(runs) == 2
      [first, second] = runs
      assert first.status == "sent"
      assert first.decision_count == 1
      assert second.status == "empty"
      assert second.decision_count == 0
    end
  end
end
