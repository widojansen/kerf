defmodule ExClaw.Agents.EmailTriage.EmailTriageTest do
  use ExClaw.DataCase

  alias ExClaw.Agents.EmailTriage.EmailTriage
  alias ExClaw.KnowledgeBase.{Document, Chunk, EmailSender, Interest}

  @fake_embedding List.duplicate(0.1, 1024)

  setup do
    # Insert a test document
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{
          source_type: "email",
          source_id: "msg_triage_1",
          title: "Q2 Invoice Processing Update",
          raw_text: "Q2 extraction pipeline processed 12,400 invoices with 98.3% accuracy.",
          source_metadata: %{
            "sender" => "john@example.com",
            "sender_name" => "John Doe",
            "thread_id" => "thread_t1",
            "subject" => "Q2 Invoice Processing Update"
          }
        })
      )

    # Insert chunk with embedding
    {:ok, _chunk} =
      Repo.insert(
        Chunk.changeset(%Chunk{}, %{
          document_id: doc.id,
          chunk_index: 0,
          content: "Q2 extraction pipeline processed 12,400 invoices with 98.3% accuracy.",
          embedding: Pgvector.new(@fake_embedding),
          token_count: 15
        })
      )

    # Insert sender
    {:ok, _sender} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "john@example.com",
          name: "John Doe",
          domain: "example.com",
          priority_score: 0.7,
          is_priority: true,
          total_emails: 10
        })
      )

    # Insert interest
    {:ok, _interest} =
      Repo.insert(
        Interest.changeset(%Interest{}, %{
          topic: "Invoice Processing",
          keywords: ["invoice", "extraction"],
          weight: 1.5,
          embedding: Pgvector.new(@fake_embedding),
          enabled: true
        })
      )

    %{doc: doc}
  end

  defp start_agent(ctx, overrides \\ []) do
    name = :"triage_#{System.unique_integer([:positive])}"

    classifier_fn = fn email, opts ->
      {:ok,
       %{
         category: "business",
         priority: 4,
         action: "follow_up",
         confidence: 0.92,
         summary: "Important business email about #{email.subject}."
       }}
    end

    telegram_fn = fn _chat_id, _text, _opts -> :ok end

    opts =
      Keyword.merge(
        [
          name: name,
          repo: ExClaw.Repo,
          classifier_fn: classifier_fn,
          telegram_fn: telegram_fn,
          graph_enabled: false,
          interest_threshold: 0.0,
          high_priority_threshold: 4
        ],
        overrides
      )

    {:ok, pid} = EmailTriage.start_link(opts)
    allow_repo(pid)

    Map.merge(ctx, %{agent: name, pid: pid})
  end

  describe "triage/2" do
    test "classifies and scores documents", ctx do
      ctx = start_agent(ctx)

      assert {:ok, results} = EmailTriage.triage(ctx.agent, [ctx.doc.id])
      assert length(results) == 1

      result = hd(results)
      assert result.document_id == ctx.doc.id
      assert result.classification.category == "business"
      assert result.classification.priority == 4
      assert result.final_priority >= 4
    end

    test "includes sender info in results", ctx do
      ctx = start_agent(ctx)

      {:ok, [result]} = EmailTriage.triage(ctx.agent, [ctx.doc.id])
      assert result.sender_info.email == "john@example.com"
      assert result.sender_info.is_priority == true
    end

    test "includes interest matches in results", ctx do
      ctx = start_agent(ctx)

      {:ok, [result]} = EmailTriage.triage(ctx.agent, [ctx.doc.id])
      assert length(result.classification.interest_matches) >= 1
      assert hd(result.classification.interest_matches).topic == "Invoice Processing"
    end

    test "sends Telegram message for high priority", ctx do
      test_pid = self()

      telegram_fn = fn _chat_id, text, _opts ->
        send(test_pid, {:telegram_sent, text})
        :ok
      end

      ctx = start_agent(ctx, telegram_fn: telegram_fn)
      EmailTriage.triage(ctx.agent, [ctx.doc.id])

      assert_receive {:telegram_sent, text}
      assert text =~ "John Doe"
      assert text =~ "Q2 Invoice Processing Update"
    end

    test "handles missing document gracefully", ctx do
      ctx = start_agent(ctx)
      fake_id = Ecto.UUID.generate()

      assert {:ok, []} = EmailTriage.triage(ctx.agent, [fake_id])
    end

    test "returns error when classifier fails", ctx do
      classifier_fn = fn _email, _opts -> {:error, "LLM down"} end
      ctx = start_agent(ctx, classifier_fn: classifier_fn)

      assert {:ok, results} = EmailTriage.triage(ctx.agent, [ctx.doc.id])
      # Failed classification is skipped, not crash
      assert results == []
    end
  end

  describe "gmail actions after triage" do
    test "marks non-priority emails as read and labels them", ctx do
      test_pid = self()

      gmail_fn = fn _token, msg_id, opts ->
        send(test_pid, {:gmail_modify, msg_id, opts})
        :ok
      end

      # Classifier returns low-priority newsletter
      classifier_fn = fn _email, _opts ->
        {:ok, %{category: "newsletter", priority: 2, action: "archive",
                confidence: 0.9, summary: "Newsletter."}}
      end

      ctx = start_agent(ctx,
        classifier_fn: classifier_fn,
        gmail_fn: gmail_fn,
        high_priority_threshold: 4
      )

      EmailTriage.triage(ctx.agent, [ctx.doc.id])

      assert_receive {:gmail_modify, "msg_triage_1", opts}
      assert "UNREAD" in Keyword.get(opts, :remove, [])
      assert Enum.any?(Keyword.get(opts, :add, []), &(&1 =~ "Triaged"))
    end

    test "keeps high-priority personal emails unread", ctx do
      test_pid = self()

      gmail_fn = fn _token, msg_id, opts ->
        send(test_pid, {:gmail_modify, msg_id, opts})
        :ok
      end

      # Classifier returns high-priority personal
      classifier_fn = fn _email, _opts ->
        {:ok, %{category: "personal", priority: 5, action: "follow_up",
                confidence: 0.95, summary: "Important personal email."}}
      end

      ctx = start_agent(ctx,
        classifier_fn: classifier_fn,
        gmail_fn: gmail_fn,
        high_priority_threshold: 4
      )

      EmailTriage.triage(ctx.agent, [ctx.doc.id])

      assert_receive {:gmail_modify, "msg_triage_1", opts}
      refute "UNREAD" in Keyword.get(opts, :remove, [])
      assert Enum.any?(Keyword.get(opts, :add, []), &(&1 =~ "Triaged"))
    end

    test "does not crash when gmail_fn is not set", ctx do
      ctx = start_agent(ctx)
      assert {:ok, [_result]} = EmailTriage.triage(ctx.agent, [ctx.doc.id])
    end

    test "does not crash when gmail_fn fails", ctx do
      gmail_fn = fn _token, _msg_id, _opts -> {:error, "Gmail API down"} end

      ctx = start_agent(ctx, gmail_fn: gmail_fn)
      assert {:ok, [_result]} = EmailTriage.triage(ctx.agent, [ctx.doc.id])
    end
  end

  describe "status/1" do
    test "returns agent status", ctx do
      ctx = start_agent(ctx)
      status = EmailTriage.status(ctx.agent)

      assert is_map(status)
      assert Map.has_key?(status, :documents_triaged)
    end
  end
end
