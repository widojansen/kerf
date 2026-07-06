defmodule Kerf.Agents.EmailTriage.ReconcilerTest do
  # SPEC C Part 2 — RED. Orphan reconciler: a cron enqueuer (Reconciler) + a
  # per-doc worker (ReconcileDoc). Oban testing :manual. The triage seam is
  # injected (config triage_fn / the GenServer's classifier_fn) so tests never
  # hit the classifier backend.
  use Kerf.DataCase
  use Oban.Testing, repo: Kerf.Repo

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.{
    Reconciler,
    ReconcileDoc,
    EmailTriage,
    OrphanQuery,
    TriageRecord,
    Enricher
  }

  alias Kerf.KnowledgeBase.Document

  # Fixed timestamp well before (now - grace) for any realistic grace window.
  @old ~U[2026-06-01 08:00:00.000000Z]

  # ---------- fixtures ----------

  defp insert_orphan!(inserted_at) do
    %Document{}
    |> Document.changeset(%{
      source_type: "email",
      source_id: "src_#{System.unique_integer([:positive])}",
      title: "Subject",
      raw_text: "Body.",
      source_metadata: %{
        "sender" => "sender_#{System.unique_integer([:positive])}@example.com",
        "sender_name" => "Sender",
        "labels" => ["INBOX"]
      }
    })
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, inserted_at)
    |> Repo.insert!()
  end

  defp insert_triage!(doc) do
    %TriageRecord{}
    |> TriageRecord.classify_changeset(%{
      document_id: doc.id,
      category: "business",
      sender_type: "known_routine",
      classifier_source: "fast_classifier",
      confidence: 1.0
    })
    |> Repo.insert!()
  end

  # A real EmailTriage GenServer with a stubbed classifier (no gmail/telegram),
  # so the reconcile path exercises the true triage → row + Enricher enqueue.
  defp start_stub_triage_agent do
    name = :"recon_triage_#{System.unique_integer([:positive])}"

    classifier_fn = fn _email, _opts ->
      {:ok,
       %{category: "business", priority: 2, action: "review", confidence: 0.9, summary: "stub"}}
    end

    {:ok, pid} =
      EmailTriage.start_link(
        name: name,
        repo: Kerf.Repo,
        classifier_fn: classifier_fn,
        interest_threshold: 0.0,
        high_priority_threshold: 4
      )

    allow_repo(pid)
    name
  end

  defp set_reconciler_config(kw) do
    prev = Application.get_env(:kerf, Reconciler, [])
    Application.put_env(:kerf, Reconciler, Keyword.merge(prev, kw))
    on_exit(fn -> Application.put_env(:kerf, Reconciler, prev) end)
  end

  defp set_reconcile_doc_triage_fn(fun) do
    prev = Application.get_env(:kerf, ReconcileDoc, [])
    Application.put_env(:kerf, ReconcileDoc, Keyword.put(prev, :triage_fn, fun))
    on_exit(fn -> Application.put_env(:kerf, ReconcileDoc, prev) end)
  end

  defp reconcile_docs_enqueued_for(doc_id) do
    all_enqueued(worker: ReconcileDoc)
    |> Enum.filter(&(&1.args["document_id"] == doc_id))
  end

  # ---------- Reconciler (cron enqueuer) ----------

  describe "Reconciler.perform/1 (cron enqueuer)" do
    test "(f) enqueues one ReconcileDoc per orphan older than grace, up to limit" do
      set_reconciler_config(limit: 3, grace_seconds: 600)

      for _ <- 1..5, do: insert_orphan!(@old)

      assert :ok = perform_job(Reconciler, %{})

      jobs = all_enqueued(worker: ReconcileDoc)
      assert length(jobs) == 3

      for j <- jobs do
        assert is_binary(j.args["document_id"])
      end
    end

    test "(k) an orphan within the grace window is not enqueued" do
      set_reconciler_config(limit: 20, grace_seconds: 600)

      fresh = insert_orphan!(DateTime.utc_now(:microsecond))

      assert :ok = perform_job(Reconciler, %{})

      refute_enqueued(worker: ReconcileDoc, args: %{"document_id" => fresh.id})
    end

    test "(m) singleton: unique on [:worker] blocks a second concurrent Reconciler enqueue" do
      {:ok, _} = Oban.insert(Reconciler.new(%{}))
      {:ok, _} = Oban.insert(Reconciler.new(%{}))

      assert length(all_enqueued(worker: Reconciler)) == 1
    end
  end

  # ---------- ReconcileDoc (per-doc worker) ----------

  describe "ReconcileDoc.perform/1 (per-doc)" do
    test "(g) triage success → email_triage row exists, Enricher enqueued, returns :ok" do
      doc = insert_orphan!(@old)
      agent = start_stub_triage_agent()
      set_reconcile_doc_triage_fn(fn id -> EmailTriage.triage(agent, [id]) end)

      assert :ok = perform_job(ReconcileDoc, %{"document_id" => doc.id})

      record = Repo.get_by(TriageRecord, document_id: doc.id)
      assert record != nil

      assert_enqueued(
        worker: Enricher,
        args: %{"triage_record_id" => record.id, "enrichment_version" => 1}
      )
    end

    test "(h) triage SKIP ({:ok, []}) → perform fails, must not look like success" do
      doc = insert_orphan!(@old)
      set_reconcile_doc_triage_fn(fn _id -> {:ok, []} end)

      result = perform_job(ReconcileDoc, %{"document_id" => doc.id})

      refute result == :ok
      assert match?({:error, _}, result)
    end

    test "(i) triage {:error, _} → perform fails" do
      doc = insert_orphan!(@old)
      set_reconcile_doc_triage_fn(fn _id -> {:error, "classifier down"} end)

      result = perform_job(ReconcileDoc, %{"document_id" => doc.id})

      assert match?({:error, _}, result)
    end

    test "(n) unique on document_id blocks double-enqueue; recovered doc drops out of orphan query" do
      doc = insert_orphan!(@old)

      {:ok, _} = Oban.insert(ReconcileDoc.new(%{document_id: doc.id}))
      {:ok, _} = Oban.insert(ReconcileDoc.new(%{document_id: doc.id}))

      assert length(reconcile_docs_enqueued_for(doc.id)) == 1

      # once recovered (email_triage row exists) the doc is no longer an orphan
      insert_triage!(doc)
      refute doc.id in OrphanQuery.orphan_document_ids(50)
    end
  end

  # ---------- interaction: discard is terminal for the cron ----------

  describe "discarded ReconcileDoc" do
    test "(j) a discarded ReconcileDoc is not re-enqueued by a later cron tick" do
      set_reconciler_config(limit: 20, grace_seconds: 600)

      # Still an orphan (no email_triage row) → the cron will try to enqueue it.
      doc = insert_orphan!(@old)

      # Simulate a ReconcileDoc that exhausted retries and was discarded.
      {:ok, job} = Oban.insert(ReconcileDoc.new(%{document_id: doc.id}))
      {1, _} = Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

      assert :ok = perform_job(Reconciler, %{})

      # unique includes :discarded → no new enqueued ReconcileDoc for this doc.
      assert reconcile_docs_enqueued_for(doc.id) == []
    end
  end
end
