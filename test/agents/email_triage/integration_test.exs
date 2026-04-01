defmodule ExClaw.Agents.EmailTriage.IntegrationTest do
  @moduledoc """
  Integration test for the full email triage lifecycle:
  Gmail poll → ingest → triage → Telegram output → feedback → learning.
  """
  use ExClaw.DataCase

  alias ExClaw.Ingestors.Email.EmailIngestor
  alias ExClaw.Agents.EmailTriage.{EmailTriage, FeedbackHandler}
  alias ExClaw.KnowledgeBase.{Document, EmailSender, Interest, Feedback}

  @fake_embedding List.duplicate(0.1, 768)

  @sample_email %{
    id: "msg_integration_1",
    thread_id: "thread_int_1",
    from: %{email: "ceo@acme.com", name: "CEO"},
    to: [%{email: "alice@example.com", name: "Alice"}],
    cc: [],
    subject: "Strategic AI Initiative",
    body_text: "We need to discuss the AI and machine learning strategy for Q3. This involves deep learning model deployment on our NVIDIA infrastructure.",
    body_html: nil,
    date: "Tue, 01 Apr 2026 09:00:00 +0000",
    labels: ["INBOX", "IMPORTANT"],
    snippet: "We need to discuss...",
    history_id: "60000"
  }

  setup do
    # Seed an interest
    {:ok, _} =
      Repo.insert(
        Interest.changeset(%Interest{}, %{
          topic: "AI/ML",
          keywords: ["artificial intelligence", "machine learning", "deep learning"],
          weight: 1.5,
          embedding: Pgvector.new(@fake_embedding),
          enabled: true
        })
      )

    :ok
  end

  test "full lifecycle: ingest → triage → feedback → learning" do
    # -- Step 1: Ingest --
    ingestor_name = :"int_ingestor_#{System.unique_integer([:positive])}"

    {:ok, ingestor_pid} =
      EmailIngestor.start_link(
        name: ingestor_name,
        repo: ExClaw.Repo,
        gmail_client: fn _token, _opts -> {:ok, [@sample_email], "60001"} end,
        embedder: fn _texts, _opts -> {:ok, [@fake_embedding]} end,
        poll_interval_ms: :infinity,
        access_token_fn: fn -> {:ok, "test_token"} end,
        graph_enabled: false
      )

    allow_repo(ingestor_pid)
    assert {:ok, 1} = EmailIngestor.sync_now(ingestor_name)

    # Verify document was created
    [doc] = Repo.all(Document)
    assert doc.source_type == "email"
    assert doc.title == "Strategic AI Initiative"

    # -- Step 2: Triage --
    test_pid = self()

    triage_name = :"int_triage_#{System.unique_integer([:positive])}"

    {:ok, triage_pid} =
      EmailTriage.start_link(
        name: triage_name,
        repo: ExClaw.Repo,
        classifier_fn: fn email, _opts ->
          {:ok, %{
            category: "business",
            priority: 5,
            action: "follow_up",
            confidence: 0.95,
            summary: "CEO wants to discuss AI strategy for Q3."
          }}
        end,
        telegram_fn: fn _chat_id, text, _opts ->
          send(test_pid, {:telegram, text})
          :ok
        end,
        graph_enabled: false,
        interest_threshold: 0.0,
        high_priority_threshold: 4
      )

    allow_repo(triage_pid)

    assert {:ok, [result]} = EmailTriage.triage(triage_name, [doc.id])
    assert result.final_priority >= 4
    assert result.classification.category == "business"

    # Verify Telegram message was sent
    assert_receive {:telegram, text}
    assert text =~ "CEO"
    assert text =~ "Strategic AI Initiative"

    # -- Step 3: Feedback --
    assert :ok = FeedbackHandler.handle_follow_up(doc.id, repo: Repo)

    # Verify feedback was recorded
    assert Repo.aggregate(Feedback, :count) == 1

    # Verify sender interactions were incremented
    sender = Repo.get_by!(EmailSender, email: "ceo@acme.com")
    assert sender.total_interactions == 1

    # -- Step 4: Add to priority --
    assert :ok = FeedbackHandler.handle_add_priority(doc.id, repo: Repo)

    sender = Repo.get_by!(EmailSender, email: "ceo@acme.com")
    assert sender.is_priority == true

    # Verify multiple feedbacks recorded
    assert Repo.aggregate(Feedback, :count) == 2
  end

  test "low priority emails get digest format" do
    ingestor_name = :"int_ingestor_lo_#{System.unique_integer([:positive])}"

    low_email = %{@sample_email |
      id: "msg_low_1",
      from: %{email: "news@example.com", name: "Newsletter"},
      subject: "Weekly Digest",
      body_text: "This week's news..."
    }

    {:ok, ingestor_pid} =
      EmailIngestor.start_link(
        name: ingestor_name,
        repo: ExClaw.Repo,
        gmail_client: fn _token, _opts -> {:ok, [low_email], "70001"} end,
        embedder: fn _texts, _opts -> {:ok, [@fake_embedding]} end,
        poll_interval_ms: :infinity,
        access_token_fn: fn -> {:ok, "test_token"} end,
        graph_enabled: false
      )

    allow_repo(ingestor_pid)
    {:ok, 1} = EmailIngestor.sync_now(ingestor_name)

    [doc] = Repo.all(Document)

    test_pid = self()
    triage_name = :"int_triage_lo_#{System.unique_integer([:positive])}"

    {:ok, triage_pid} =
      EmailTriage.start_link(
        name: triage_name,
        repo: ExClaw.Repo,
        classifier_fn: fn _email, _opts ->
          {:ok, %{
            category: "newsletter",
            priority: 1,
            action: "archive",
            confidence: 0.9,
            summary: "Weekly newsletter."
          }}
        end,
        telegram_fn: fn _chat_id, text, _opts ->
          send(test_pid, {:telegram, text})
          :ok
        end,
        graph_enabled: false,
        interest_threshold: 0.0,
        high_priority_threshold: 4
      )

    allow_repo(triage_pid)

    {:ok, [result]} = EmailTriage.triage(triage_name, [doc.id])
    assert result.final_priority < 4

    # Should receive digest (not full detail)
    assert_receive {:telegram, text}
    assert text =~ "Digest"
  end
end
