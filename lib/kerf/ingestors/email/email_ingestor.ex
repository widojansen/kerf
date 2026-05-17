defmodule Kerf.Ingestors.Email.EmailIngestor do
  @moduledoc """
  Polls Gmail for new emails, stores them in the knowledge base,
  generates embeddings, and builds the AGE graph.
  """
  use GenServer

  alias Kerf.KnowledgeBase.{Document, Chunk, EmailSender, Chunker}

  import Ecto.Query

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync_now(name) do
    GenServer.call(name, :sync_now, 60_000)
  end

  def backfill(name, opts \\ []) do
    GenServer.call(name, {:backfill, opts}, 60_000)
  end

  def status(name) do
    GenServer.call(name, :status)
  end

  # --- Callbacks ---

  # Hard timeout for poll tasks — prevents GenServer from blocking on hung HTTP requests
  @poll_timeout_ms 120_000

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      gmail_client: Keyword.get(opts, :gmail_client),
      gmail_search: Keyword.get(opts, :gmail_search),
      embedder: Keyword.get(opts, :embedder, &default_embedder/2),
      access_token_fn: Keyword.get(opts, :access_token_fn, fn -> {:error, "no token configured"} end),
      triage_fn: Keyword.get(opts, :triage_fn),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 300_000),
      poll_timeout_ms: Keyword.get(opts, :poll_timeout_ms, @poll_timeout_ms),
      graph_enabled: Keyword.get(opts, :graph_enabled, false),
      poll_task: nil,
      poll_pid: nil,
      poll_timer: nil,
      history_id: nil,
      last_sync: nil,
      emails_processed: 0
    }

    if state.poll_interval_ms != :infinity do
      Process.send_after(self(), :poll, 10_000)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    case do_sync(state) do
      {:ok, count, new_state} ->
        {:reply, {:ok, count}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:backfill, opts}, _from, state) do
    case do_backfill(state, opts) do
      {:ok, count, new_state} ->
        {:reply, {:ok, count}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      last_sync: state.last_sync,
      emails_processed: state.emails_processed,
      history_id: state.history_id
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:poll, %{poll_task: ref} = state) when is_reference(ref) do
    # Previous poll still running — skip this tick, reschedule
    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    parent = self()

    pid =
      spawn(fn ->
        result = do_sync(state)
        send(parent, {:poll_result, result})
      end)

    ref = Process.monitor(pid)
    timer = Process.send_after(self(), {:poll_timeout, pid, ref}, state.poll_timeout_ms)
    {:noreply, %{state | poll_task: ref, poll_pid: pid, poll_timer: timer}}
  end

  def handle_info({:poll_result, result}, %{poll_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    cancel_poll_timer(state)

    state =
      case result do
        {:ok, _count, new_state} -> %{new_state | poll_task: nil, poll_pid: nil, poll_timer: nil}
        {:error, _reason, new_state} -> %{new_state | poll_task: nil, poll_pid: nil, poll_timer: nil}
      end

    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info({:poll_timeout, pid, ref}, %{poll_task: ref} = state) do
    require Logger
    Logger.warning("[EmailIngestor] Poll task timed out after #{state.poll_timeout_ms}ms, killing")
    Process.exit(pid, :kill)
    # The :DOWN message will clean up poll_task
    {:noreply, %{state | poll_timer: nil}}
  end

  def handle_info({:poll_timeout, _pid, _ref}, state) do
    # Stale timeout for an already-completed task — ignore
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{poll_task: ref} = state) do
    require Logger
    if reason != :normal, do: Logger.warning("[EmailIngestor] Poll task exited: #{inspect(reason)}")
    cancel_poll_timer(state)
    state = %{state | poll_task: nil, poll_pid: nil, poll_timer: nil}
    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Stale DOWN from a previous poll — ignore
    {:noreply, state}
  end

  # --- Internal ---

  defp schedule_poll(state) do
    if state.poll_interval_ms != :infinity do
      Process.send_after(self(), :poll, state.poll_interval_ms)
    end
  end

  defp cancel_poll_timer(%{poll_timer: nil}), do: :ok
  defp cancel_poll_timer(%{poll_timer: timer}), do: Process.cancel_timer(timer)

  defp do_sync(state) do
    with {:ok, access_token} <- state.access_token_fn.(),
         gmail_opts = if(state.history_id, do: [history_id: state.history_id], else: []),
         {:ok, emails, new_history_id} <- state.gmail_client.(access_token, gmail_opts) do
      count = ingest_emails(emails, state)

      new_state = %{
        state
        | history_id: new_history_id || state.history_id,
          last_sync: DateTime.utc_now(),
          emails_processed: state.emails_processed + count
      }

      {:ok, count, new_state}
    else
      {:error, :history_expired} ->
        # History ID expired — reset and retry via messages.list
        do_sync(%{state | history_id: nil})

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_backfill(state, opts) do
    query = Keyword.get(opts, :query, "")
    search_fn = state.gmail_search || state.gmail_client

    with {:ok, access_token} <- state.access_token_fn.(),
         {:ok, emails} <- search_fn.(access_token, query, []) do
      count = ingest_emails(emails, state)
      {:ok, count, state}
    end
  end

  defp ingest_emails(emails, state) do
    repo = state.repo

    doc_ids =
      Enum.reduce(emails, [], fn email, acc ->
        content_hash =
          :crypto.hash(:sha256, email.body_text || "")
          |> Base.encode16(case: :lower)

        # Check dedup by source_id
        existing =
          repo.one(
            from(d in Document,
              where: d.source_type == "email" and d.source_id == ^email.id
            )
          )

        if existing do
          acc
        else
          case insert_email_document(email, content_hash, repo) do
            {:ok, doc} ->
              insert_chunks(doc, email, state)
              upsert_sender(email, repo)
              [doc.id | acc]

            {:error, _} ->
              acc
          end
        end
      end)

    if doc_ids != [] and state.triage_fn do
      try do
        state.triage_fn.(Enum.reverse(doc_ids))
      rescue
        e ->
          require Logger

          Logger.error(
            "[EmailIngestor] triage_fn failed for #{length(doc_ids)} doc(s): " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          :ok
      catch
        kind, value ->
          require Logger

          Logger.error(
            "[EmailIngestor] triage_fn caught #{kind} for #{length(doc_ids)} doc(s): " <>
              inspect(value, limit: 200) <>
              " stacktrace=" <> Exception.format_stacktrace(__STACKTRACE__)
          )

          :ok
      end
    end

    length(doc_ids)
  end

  defp insert_email_document(email, content_hash, repo) do
    attrs = %{
      source_type: "email",
      source_id: email.id,
      source_metadata: %{
        "sender" => email.from.email,
        "sender_name" => email.from.name,
        "thread_id" => email.thread_id,
        "subject" => email.subject,
        "labels" => email.labels,
        "date" => email.date
      },
      title: email.subject,
      raw_text: email.body_text,
      content_hash: content_hash,
      processed_at: DateTime.utc_now()
    }

    %Document{}
    |> Document.changeset(attrs)
    |> repo.insert()
  end

  defp insert_chunks(doc, email, state) do
    text = email.body_text || ""

    if String.trim(text) != "" do
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 512)
      texts = Enum.map(chunks, & &1.content)

      embeddings =
        case state.embedder.(texts, []) do
          {:ok, embs} -> embs
          {:error, _} -> List.duplicate(nil, length(texts))
        end

      Enum.zip(chunks, embeddings)
      |> Enum.each(fn {chunk_data, embedding} ->
        attrs = %{
          document_id: doc.id,
          chunk_index: chunk_data.index,
          content: chunk_data.content,
          token_count: chunk_data.token_count,
          embedding: if(embedding, do: Pgvector.new(embedding), else: nil)
        }

        %Chunk{}
        |> Chunk.changeset(attrs)
        |> state.repo.insert()
      end)
    end
  end

  defp upsert_sender(email, repo) do
    sender_email = email.from.email
    domain = sender_email |> String.split("@") |> List.last()
    now = DateTime.utc_now()

    attrs = %{
      email: sender_email,
      name: email.from.name,
      domain: domain,
      total_emails: 1,
      last_email_at: now
    }

    case repo.one(from(s in EmailSender, where: s.email == ^sender_email)) do
      nil ->
        %EmailSender{}
        |> EmailSender.changeset(attrs)
        |> repo.insert()

      existing ->
        existing
        |> EmailSender.changeset(%{
          name: email.from.name || existing.name,
          total_emails: existing.total_emails + 1,
          last_email_at: now
        })
        |> repo.update()
    end
  end

  defp default_embedder(texts, opts) do
    Kerf.KnowledgeBase.Embedder.embed_batch(texts, opts)
  end
end
