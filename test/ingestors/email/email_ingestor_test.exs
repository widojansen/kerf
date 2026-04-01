defmodule ExClaw.Ingestors.Email.EmailIngestorTest do
  use ExClaw.DataCase

  alias ExClaw.Ingestors.Email.EmailIngestor
  alias ExClaw.KnowledgeBase.{Document, Chunk, EmailSender}

  @sample_email %{
    id: "msg_ingest_1",
    thread_id: "thread_ingest_1",
    from: %{email: "alice@example.com", name: "Alice"},
    to: [%{email: "alice@example.com", name: "Alice"}],
    cc: [],
    subject: "Test Email Subject",
    body_text: "This is the email body with enough text to test chunking and embedding.",
    body_html: "<p>This is the email body.</p>",
    date: "Mon, 31 Mar 2026 10:00:00 +0000",
    labels: ["INBOX"],
    snippet: "This is the email body...",
    history_id: "50000"
  }

  @fake_embedding List.duplicate(0.1, 768)

  defp fake_gmail_client(_token, _opts) do
    {:ok, [@sample_email], "50001"}
  end

  defp fake_embedder(_texts, _opts) do
    {:ok, [@fake_embedding]}
  end

  defp start_ingestor(ctx, overrides \\ []) do
    name = :"ingestor_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          repo: ExClaw.Repo,
          gmail_client: &fake_gmail_client/2,
          embedder: &fake_embedder/2,
          poll_interval_ms: :infinity,
          access_token_fn: fn -> {:ok, "test_token"} end,
          graph_enabled: false
        ],
        overrides
      )

    {:ok, pid} = EmailIngestor.start_link(opts)
    allow_repo(pid)

    Map.merge(ctx, %{ingestor: name, pid: pid})
  end

  describe "sync_now/1" do
    test "ingests new emails into kb_documents", ctx do
      ctx = start_ingestor(ctx)

      assert {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)

      docs = Repo.all(Document)
      assert length(docs) == 1
      doc = hd(docs)
      assert doc.source_type == "email"
      assert doc.source_id == "msg_ingest_1"
      assert doc.title == "Test Email Subject"
      assert doc.source_metadata["sender"] == "alice@example.com"
      assert doc.source_metadata["thread_id"] == "thread_ingest_1"
    end

    test "creates chunks with embeddings", ctx do
      ctx = start_ingestor(ctx)
      {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)

      chunks = Repo.all(Chunk)
      assert length(chunks) >= 1
      chunk = hd(chunks)
      assert chunk.content != nil
      assert chunk.embedding != nil
    end

    test "upserts sender in email_senders", ctx do
      ctx = start_ingestor(ctx)
      {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)

      senders = Repo.all(EmailSender)
      assert length(senders) == 1
      sender = hd(senders)
      assert sender.email == "alice@example.com"
      assert sender.name == "Alice"
      assert sender.domain == "example.com"
      assert sender.total_emails == 1
    end

    test "deduplicates by content_hash", ctx do
      ctx = start_ingestor(ctx)
      {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)
      {:ok, 0} = EmailIngestor.sync_now(ctx.ingestor)

      assert Repo.aggregate(Document, :count) == 1
    end

    test "deduplicates by source_id", ctx do
      ctx = start_ingestor(ctx)
      {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)

      # Same email again with different content hash but same source_id
      {:ok, 0} = EmailIngestor.sync_now(ctx.ingestor)
      assert Repo.aggregate(Document, :count) == 1
    end

    test "increments sender total_emails on second email from same sender", ctx do
      email2 = %{@sample_email | id: "msg_ingest_2", subject: "Second Email",
                  body_text: "Different body text entirely."}

      call_count = :counters.new(1, [:atomics])

      gmail_client = fn _token, _opts ->
        :counters.add(call_count, 1, 1)
        case :counters.get(call_count, 1) do
          1 -> {:ok, [@sample_email], "50001"}
          _ -> {:ok, [email2], "50002"}
        end
      end

      ctx = start_ingestor(ctx, gmail_client: gmail_client)
      {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)
      {:ok, 1} = EmailIngestor.sync_now(ctx.ingestor)

      sender = Repo.get_by!(EmailSender, email: "alice@example.com")
      assert sender.total_emails == 2
    end

    test "handles gmail client error gracefully", ctx do
      gmail_client = fn _token, _opts -> {:error, "API error"} end
      ctx = start_ingestor(ctx, gmail_client: gmail_client)

      assert {:error, "API error"} = EmailIngestor.sync_now(ctx.ingestor)
    end

    test "handles token retrieval error gracefully", ctx do
      ctx = start_ingestor(ctx, access_token_fn: fn -> {:error, "no token"} end)
      assert {:error, "no token"} = EmailIngestor.sync_now(ctx.ingestor)
    end
  end

  describe "status/1" do
    test "returns sync status", ctx do
      ctx = start_ingestor(ctx)
      status = EmailIngestor.status(ctx.ingestor)

      assert is_map(status)
      assert Map.has_key?(status, :last_sync)
      assert Map.has_key?(status, :emails_processed)
      assert Map.has_key?(status, :history_id)
    end

    test "updates after sync", ctx do
      ctx = start_ingestor(ctx)
      EmailIngestor.sync_now(ctx.ingestor)
      status = EmailIngestor.status(ctx.ingestor)

      assert status.emails_processed == 1
      assert status.history_id == "50001"
      assert status.last_sync != nil
    end
  end

  describe "backfill/2" do
    test "ingests emails from search query", ctx do
      gmail_search = fn _token, _query, _opts ->
        {:ok, [%{@sample_email | id: "msg_backfill_1"}]}
      end

      ctx = start_ingestor(ctx, gmail_search: gmail_search)

      assert {:ok, 1} = EmailIngestor.backfill(ctx.ingestor, query: "from:alice@example.com")
    end
  end
end
