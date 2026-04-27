defmodule Kerf.Agents.EmailTriage.FeedbackHandler do
  @moduledoc """
  Processes ApprovalGate callbacks for email triage feedback.
  Records feedback, updates sender scores, and learns from decisions.
  """

  alias Kerf.KnowledgeBase.{Document, EmailSender, Feedback}

  import Ecto.Query

  @priority_suggestion_threshold 3
  @ignore_score_decrement 0.05

  @doc """
  Dispatch a callback action by name.
  """
  def handle_callback(action, document_id, opts \\ []) do
    case action do
      "follow_up" -> handle_follow_up(document_id, opts)
      "archive" -> handle_archive(document_id, opts)
      "add_priority" -> handle_add_priority(document_id, opts)
      "ignore" -> handle_ignore(document_id, opts)
      _ -> {:error, :unknown_action}
    end
  end

  @doc """
  Handle "Follow up" feedback.
  Records feedback, increments sender interactions.
  Returns `:suggest_priority` if sender crosses interaction threshold.
  """
  def handle_follow_up(document_id, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)

    record_feedback(repo, document_id, "follow_up", "yes")

    case get_sender_for_document(repo, document_id) do
      nil ->
        :ok

      sender ->
        new_interactions = sender.total_interactions + 1

        sender
        |> EmailSender.changeset(%{total_interactions: new_interactions})
        |> repo.update!()

        if not sender.is_priority and new_interactions >= @priority_suggestion_threshold do
          :suggest_priority
        else
          :ok
        end
    end
  end

  @doc """
  Handle "Archive" feedback.
  """
  def handle_archive(document_id, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)
    record_feedback(repo, document_id, "archive", "approve")
    :ok
  end

  @doc """
  Handle "Add sender to priority" feedback.
  Sets sender as priority, records feedback.
  """
  def handle_add_priority(document_id, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)

    record_feedback(repo, document_id, "priority", "approve")

    case get_sender_for_document(repo, document_id) do
      nil -> :ok
      sender ->
        sender
        |> EmailSender.changeset(%{is_priority: true, priority_score: max(sender.priority_score, 0.8)})
        |> repo.update!()
        :ok
    end
  end

  @doc """
  Handle "Ignore" feedback.
  Decrements sender priority score slightly.
  """
  def handle_ignore(document_id, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)

    record_feedback(repo, document_id, "priority", "no")

    case get_sender_for_document(repo, document_id) do
      nil -> :ok
      sender ->
        new_score = max(sender.priority_score - @ignore_score_decrement, -1.0)

        sender
        |> EmailSender.changeset(%{priority_score: new_score})
        |> repo.update!()
        :ok
    end
  end

  # --- Private ---

  defp record_feedback(repo, document_id, feedback_type, decision) do
    %Feedback{}
    |> Feedback.changeset(%{
      document_id: document_id,
      feedback_type: feedback_type,
      decision: decision,
      source: "telegram"
    })
    |> repo.insert!()
  end

  defp get_sender_for_document(repo, document_id) do
    case repo.get(Document, document_id) do
      nil ->
        nil

      doc ->
        sender_email = doc.source_metadata["sender"]
        if sender_email, do: repo.one(from(s in EmailSender, where: s.email == ^sender_email))
    end
  end
end
