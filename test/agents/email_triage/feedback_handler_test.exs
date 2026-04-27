defmodule Kerf.Agents.EmailTriage.FeedbackHandlerTest do
  use Kerf.DataCase

  alias Kerf.Agents.EmailTriage.FeedbackHandler
  alias Kerf.KnowledgeBase.{Document, EmailSender, Feedback}

  setup do
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{
          source_type: "email",
          source_id: "msg_fb_1",
          title: "Feedback Test Email",
          source_metadata: %{"sender" => "alice@example.com"}
        })
      )

    {:ok, sender} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "alice@example.com",
          name: "Alice",
          domain: "example.com",
          total_interactions: 0,
          is_priority: false,
          priority_score: 0.3
        })
      )

    %{doc: doc, sender: sender}
  end

  describe "handle_follow_up/2" do
    test "records feedback", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_follow_up(doc.id, repo: Repo)

      feedbacks = Repo.all(Feedback)
      assert length(feedbacks) == 1
      fb = hd(feedbacks)
      assert fb.feedback_type == "follow_up"
      assert fb.decision == "yes"
      assert fb.document_id == doc.id
    end

    test "increments sender total_interactions", %{doc: doc} do
      FeedbackHandler.handle_follow_up(doc.id, repo: Repo)

      sender = Repo.get_by!(EmailSender, email: "alice@example.com")
      assert sender.total_interactions == 1
    end

    test "returns :suggest_priority after threshold interactions", %{doc: doc, sender: sender} do
      # Set interactions to threshold - 1
      Repo.update!(EmailSender.changeset(sender, %{total_interactions: 2}))

      result = FeedbackHandler.handle_follow_up(doc.id, repo: Repo)
      assert result == :suggest_priority
    end

    test "does not suggest priority for already-priority sender", %{doc: doc, sender: sender} do
      Repo.update!(EmailSender.changeset(sender, %{total_interactions: 5, is_priority: true}))

      result = FeedbackHandler.handle_follow_up(doc.id, repo: Repo)
      assert result == :ok
    end
  end

  describe "handle_archive/2" do
    test "records feedback", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_archive(doc.id, repo: Repo)

      fb = Repo.one!(Feedback)
      assert fb.feedback_type == "archive"
      assert fb.decision == "approve"
    end
  end

  describe "handle_add_priority/2" do
    test "sets sender is_priority to true", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_add_priority(doc.id, repo: Repo)

      sender = Repo.get_by!(EmailSender, email: "alice@example.com")
      assert sender.is_priority == true
    end

    test "records feedback", %{doc: doc} do
      FeedbackHandler.handle_add_priority(doc.id, repo: Repo)

      fb = Repo.one!(Feedback)
      assert fb.feedback_type == "priority"
      assert fb.decision == "approve"
    end
  end

  describe "handle_ignore/2" do
    test "records feedback", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_ignore(doc.id, repo: Repo)

      fb = Repo.one!(Feedback)
      assert fb.feedback_type == "priority"
      assert fb.decision == "no"
    end

    test "decrements sender priority_score slightly", %{doc: doc} do
      FeedbackHandler.handle_ignore(doc.id, repo: Repo)

      sender = Repo.get_by!(EmailSender, email: "alice@example.com")
      assert sender.priority_score < 0.3
    end
  end

  describe "handle_callback/2" do
    test "dispatches follow_up action", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_callback("follow_up", doc.id, repo: Repo)
      assert Repo.one!(Feedback).feedback_type == "follow_up"
    end

    test "dispatches archive action", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_callback("archive", doc.id, repo: Repo)
      assert Repo.one!(Feedback).feedback_type == "archive"
    end

    test "dispatches add_priority action", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_callback("add_priority", doc.id, repo: Repo)
      assert Repo.one!(Feedback).feedback_type == "priority"
    end

    test "dispatches ignore action", %{doc: doc} do
      assert :ok = FeedbackHandler.handle_callback("ignore", doc.id, repo: Repo)
      assert Repo.one!(Feedback).feedback_type == "priority"
    end

    test "returns error for unknown action", %{doc: doc} do
      assert {:error, :unknown_action} =
               FeedbackHandler.handle_callback("unknown", doc.id, repo: Repo)
    end
  end
end
