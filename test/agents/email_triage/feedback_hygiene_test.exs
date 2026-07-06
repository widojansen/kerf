defmodule Kerf.Agents.EmailTriage.FeedbackHygieneTest do
  # SPEC C Part 3 — RED. Triage feedback becomes one row per doc: on any
  # (re)triage write, clear prior triage-type kb_feedback for that document,
  # then insert. Application-level upsert-replace, migration-free. Scoped to
  # triage feedback of THAT document only.
  use Kerf.DataCase

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.EmailTriage
  alias Kerf.KnowledgeBase.{Document, Feedback}

  # ---------- fixtures ----------

  defp insert_email_doc! do
    %Document{}
    |> Document.changeset(%{
      source_type: "email",
      source_id: "src_#{System.unique_integer([:positive])}",
      title: "Subject",
      raw_text: "Body",
      source_metadata: %{"sender" => "a@example.com", "sender_name" => "A"}
    })
    |> Repo.insert!()
  end

  defp insert_feedback!(doc, fields) do
    attrs =
      Enum.into(fields, %{document_id: doc.id, context: %{}, source: "system"})

    %Feedback{}
    |> Feedback.changeset(attrs)
    |> Repo.insert!()
  end

  # The exact breadcrumb the {:error} classify-drop writes.
  defp insert_error_breadcrumb!(doc) do
    insert_feedback!(doc,
      feedback_type: "triage",
      decision: "unclassified",
      context: %{"error" => "LLM down"}
    )
  end

  defp triage_feedback_for(doc_id) do
    Repo.all(
      from(f in Feedback,
        where: f.document_id == ^doc_id and f.feedback_type == "triage"
      )
    )
  end

  @success_ctx %{category: "business", final_priority: 3, source: :llm}

  # ---------- tests ----------

  describe "upsert_triage_feedback/3" do
    test "(l) prior error breadcrumb + successful retriage → exactly one triage row (the success)" do
      doc = insert_email_doc!()
      insert_error_breadcrumb!(doc)

      EmailTriage.upsert_triage_feedback(Repo, doc.id, @success_ctx)

      rows = triage_feedback_for(doc.id)
      assert length(rows) == 1, "expected exactly one triage feedback row, got #{length(rows)}"

      [only] = rows
      # the survivor is the success record, not the cleared error breadcrumb
      assert only.decision == "classified"
    end

    test "(m) no prior feedback → one triage row after a write (normal path unchanged)" do
      doc = insert_email_doc!()

      EmailTriage.upsert_triage_feedback(Repo, doc.id, @success_ctx)

      assert length(triage_feedback_for(doc.id)) == 1
    end

    test "(n) clear is scoped: only triage feedback for THIS document is removed" do
      doc_a = insert_email_doc!()
      doc_b = insert_email_doc!()

      # doc_a: a non-triage feedback (must survive) + a prior triage breadcrumb (to be replaced)
      other_type = insert_feedback!(doc_a, feedback_type: "follow_up", decision: "yes")
      insert_error_breadcrumb!(doc_a)

      # doc_b: a triage breadcrumb (different doc — must survive)
      b_breadcrumb = insert_error_breadcrumb!(doc_b)

      EmailTriage.upsert_triage_feedback(Repo, doc_a.id, @success_ctx)

      # doc_a: exactly one triage row (the new success)
      assert length(triage_feedback_for(doc_a.id)) == 1
      # doc_a: the non-triage feedback is untouched
      assert Repo.get(Feedback, other_type.id) != nil
      # doc_b: its triage feedback is untouched
      assert Repo.get(Feedback, b_breadcrumb.id) != nil
      assert length(triage_feedback_for(doc_b.id)) == 1
    end
  end
end
