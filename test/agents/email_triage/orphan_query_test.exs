defmodule Kerf.Agents.EmailTriage.OrphanQueryTest do
  # SPEC C Part 1 — RED. Shared orphan query: email docs (source_type='email')
  # with NO email_triage row, newest-first, limited. Anti-joins on
  # email_triage.document_id — NOT on kb_feedback (the old selection's bug).
  use Kerf.DataCase

  alias Kerf.Agents.EmailTriage.{OrphanQuery, TriageRecord}
  alias Kerf.KnowledgeBase.{Document, Feedback}

  # ---------- fixtures ----------

  defp insert_doc!(source_type, inserted_at, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          source_type: source_type,
          source_id: "src_#{System.unique_integer([:positive])}",
          title: "Subject",
          raw_text: "Body",
          source_metadata: %{"sender" => "a@example.com", "sender_name" => "A"}
        },
        overrides
      )

    %Document{}
    |> Document.changeset(attrs)
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

  # The exact breadcrumb the {:error} classify-drop writes (decision "unclassified").
  defp insert_error_feedback!(doc) do
    %Feedback{}
    |> Feedback.changeset(%{
      document_id: doc.id,
      feedback_type: "triage",
      decision: "unclassified",
      context: %{"error" => "boom"},
      source: "system"
    })
    |> Repo.insert!()
  end

  @t1 ~U[2026-06-01 08:00:00.000000Z]
  @t2 ~U[2026-06-02 08:00:00.000000Z]
  @t3 ~U[2026-06-03 08:00:00.000000Z]

  # ---------- tests ----------

  describe "orphan_document_ids/1" do
    test "(a) email doc with no email_triage row → included" do
      doc = insert_doc!("email", @t1)

      ids = OrphanQuery.orphan_document_ids(50)

      assert doc.id in ids
    end

    test "(b) email doc WITH an email_triage row (+ any feedback) → excluded" do
      doc = insert_doc!("email", @t1)
      insert_triage!(doc)
      insert_error_feedback!(doc)

      ids = OrphanQuery.orphan_document_ids(50)

      refute doc.id in ids
    end

    test "(c) REGRESSION: no email_triage row but WITH a kb_feedback error breadcrumb → included" do
      # This is the 23-class the old 'no kb_feedback triage row' selection wrongly
      # skipped. It has a breadcrumb but no triage row, so it IS an orphan.
      doc = insert_doc!("email", @t1)
      insert_error_feedback!(doc)

      ids = OrphanQuery.orphan_document_ids(50)

      assert doc.id in ids
    end

    test "(d) non-email source_type → excluded" do
      doc = insert_doc!("pdf", @t1)

      ids = OrphanQuery.orphan_document_ids(50)

      refute doc.id in ids
    end

    test "(e) newest-first + limit respected" do
      oldest = insert_doc!("email", @t1)
      middle = insert_doc!("email", @t2)
      newest = insert_doc!("email", @t3)

      ids = OrphanQuery.orphan_document_ids(2)

      # exactly the two newest, newest-first; the oldest is dropped by the limit
      assert ids == [newest.id, middle.id]
      refute oldest.id in ids
    end
  end
end
