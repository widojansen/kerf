defmodule Kerf.Agents.EmailTriage.DigestRunTest do
  # Tests Step 13's two-table tracking:
  #   1. New `email_digest_runs` table (audit log per cron tick)
  #   2. New `digested_at` column on `email_routing_decisions` (drained marker)
  #   3. Partial index `WHERE digested_at IS NULL` on routing_decisions
  use Kerf.DataCase

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.{DigestRun, RoutingDecision, TriageRecord}
  alias Kerf.KnowledgeBase.Document

  # ---------- fixtures ----------

  defp insert_email_doc!(suffix) do
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{
          source_type: "email",
          source_id: "msg_dr_#{suffix}",
          title: "Subject #{suffix}",
          raw_text: "Body #{suffix}",
          source_metadata: %{"sender" => "s#{suffix}@example.com"}
        })
      )

    doc
  end

  defp insert_enriched_triage!(doc) do
    {:ok, classified} =
      %TriageRecord{}
      |> TriageRecord.classify_changeset(%{
        document_id: doc.id,
        category: "newsletter",
        sender_type: "known_routine",
        classifier_source: "fast_classifier",
        confidence: 1.0
      })
      |> Repo.insert()

    {:ok, enriched} =
      classified
      |> TriageRecord.enrich_changeset(%{
        urgency: "low",
        action: "fyi",
        topic: ["dev_tools"],
        summary: "fixture summary"
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

  # ---------- DigestRun schema ----------

  describe "DigestRun schema" do
    test "persists and reloads with all columns" do
      now = DateTime.utc_now(:microsecond)
      window_start = DateTime.add(now, -3600, :second)

      {:ok, run} =
        %DigestRun{}
        |> DigestRun.changeset(%{
          sent_at: now,
          decision_count: 5,
          status: "sent",
          error: nil,
          window_start: window_start,
          window_end: now
        })
        |> Repo.insert()

      reloaded = Repo.get!(DigestRun, run.id)
      assert reloaded.decision_count == 5
      assert reloaded.status == "sent"
      assert reloaded.error == nil
      assert %DateTime{} = reloaded.sent_at
      assert %DateTime{} = reloaded.window_start
      assert %DateTime{} = reloaded.window_end
      assert %DateTime{} = reloaded.inserted_at
    end
  end

  # ---------- email_routing_decisions digested_at column ----------

  describe "RoutingDecision digested_at column" do
    test "accepts digested_at updates (additive column behavior)" do
      doc = insert_email_doc!("col")
      triage = insert_enriched_triage!(doc)
      decision = insert_digest_decision!(triage)

      # Pre-update: digested_at is NULL (the default for queued routing decisions).
      assert decision.digested_at == nil

      digested_at = DateTime.utc_now(:microsecond)

      {:ok, updated} =
        decision
        |> Ecto.Changeset.change(digested_at: digested_at)
        |> Repo.update()

      reloaded = Repo.get!(RoutingDecision, updated.id)
      assert %DateTime{} = reloaded.digested_at
    end
  end

  # ---------- partial index ----------

  describe "partial index" do
    test "WHERE digested_at IS NULL exists on email_routing_decisions" do
      # Step 13 migration adds a partial index for the worker's hot query:
      #   SELECT ... FROM email_routing_decisions WHERE digested_at IS NULL AND ...
      # We verify the index exists via pg_indexes rather than EXPLAIN to avoid
      # depending on Postgres version-specific plan output. Postgres uses
      # partial indexes automatically when queries match the predicate.
      {:ok, result} =
        Ecto.Adapters.SQL.query(
          Repo,
          """
          SELECT indexname, indexdef
          FROM pg_indexes
          WHERE tablename = 'email_routing_decisions'
            AND indexdef ILIKE '%digested_at IS NULL%'
          """,
          []
        )

      assert length(result.rows) > 0,
             "Expected a partial index with `WHERE digested_at IS NULL` on email_routing_decisions"
    end
  end
end
