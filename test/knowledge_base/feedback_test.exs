defmodule ExClaw.KnowledgeBase.FeedbackTest do
  use ExClaw.DataCase

  alias ExClaw.KnowledgeBase.{Document, Feedback}

  describe "changeset/2" do
    test "valid with required fields" do
      cs =
        Feedback.changeset(%Feedback{}, %{
          feedback_type: "priority",
          decision: "yes"
        })

      assert cs.valid?
    end

    test "requires feedback_type" do
      cs = Feedback.changeset(%Feedback{}, %{decision: "yes"})
      refute cs.valid?
      assert %{feedback_type: ["can't be blank"]} = errors_on(cs)
    end

    test "requires decision" do
      cs = Feedback.changeset(%Feedback{}, %{feedback_type: "priority"})
      refute cs.valid?
      assert %{decision: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "insert" do
    test "inserts feedback with defaults" do
      {:ok, fb} =
        Repo.insert(
          Feedback.changeset(%Feedback{}, %{
            feedback_type: "follow_up",
            decision: "yes"
          })
        )

      assert fb.source == "telegram"
      assert fb.context == %{}
      assert fb.document_id == nil
    end

    test "inserts feedback linked to document" do
      {:ok, doc} =
        Repo.insert(
          Document.changeset(%Document{}, %{source_type: "email", source_id: "msg_fb_test"})
        )

      {:ok, fb} =
        Repo.insert(
          Feedback.changeset(%Feedback{}, %{
            document_id: doc.id,
            feedback_type: "archive",
            decision: "approve",
            context: %{"subject" => "Test email"},
            source: "dashboard"
          })
        )

      assert fb.document_id == doc.id
      assert fb.context["subject"] == "Test email"
    end

    test "nilifies document_id on document delete" do
      {:ok, doc} =
        Repo.insert(
          Document.changeset(%Document{}, %{source_type: "email", source_id: "msg_fb_del"})
        )

      {:ok, fb} =
        Repo.insert(
          Feedback.changeset(%Feedback{}, %{
            document_id: doc.id,
            feedback_type: "priority",
            decision: "yes"
          })
        )

      Repo.delete!(doc)
      reloaded = Repo.get!(Feedback, fb.id)
      assert reloaded.document_id == nil
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
