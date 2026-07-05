defmodule Kerf.Agents.EmailTriage.EmailTriage do
  @moduledoc """
  Classifies new emails, scores priority, generates summaries,
  and surfaces results to Telegram with approval buttons.
  """
  use GenServer
  require Logger

  alias Kerf.KnowledgeBase.{Document, Chunk, EmailSender, Feedback, Interest}
  alias Kerf.Agents.EmailTriage.{
    Classifier,
    Enricher,
    FastClassifier,
    InterestMatcher,
    PriorityScorer,
    TelegramFormatter,
    TriageRecord
  }

  import Ecto.Query

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def triage(name, document_ids) do
    GenServer.call(name, {:triage, document_ids}, 120_000)
  end

  def status(name) do
    GenServer.call(name, :status)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      classifier_fn: Keyword.get(opts, :classifier_fn, &default_classifier/2),
      telegram_fn: Keyword.get(opts, :telegram_fn),
      gmail_fn: Keyword.get(opts, :gmail_fn),
      gmail_label: Keyword.get(opts, :gmail_label, "Kerf/Triaged"),
      graph_enabled: Keyword.get(opts, :graph_enabled, false),
      interest_threshold: Keyword.get(opts, :interest_threshold, 0.5),
      high_priority_threshold: Keyword.get(opts, :high_priority_threshold, 4),
      documents_triaged: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:triage, document_ids}, _from, state) do
    results =
      document_ids
      |> Enum.flat_map(fn doc_id ->
        try do
          triage_document(doc_id, state)
        rescue
          e ->
            Logger.warning(
              "[EmailTriage] triage_document failed for #{inspect(doc_id)}: " <>
                Exception.format(:error, e) <>
                " stacktrace=" <> Exception.format_stacktrace(__STACKTRACE__)
            )

            []
        catch
          kind, value ->
            Logger.warning(
              "[EmailTriage] triage_document caught #{kind} for #{inspect(doc_id)}: " <>
                inspect(value, limit: 200) <>
                " stacktrace=" <> Exception.format_stacktrace(__STACKTRACE__)
            )

            []
        end
      end)

    new_state = %{state | documents_triaged: state.documents_triaged + length(results)}

    # Send Telegram notifications
    send_notifications(results, state)

    {:reply, {:ok, results}, new_state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{documents_triaged: state.documents_triaged}, state}
  end

  # --- Internal ---

  defp triage_document(doc_id, state) do
    repo = state.repo

    case repo.get(Document, doc_id) do
      nil ->
        []

      doc ->
        # 1. Lookup sender
        sender_info = lookup_sender(doc, repo)

        # 2. Get email embedding (first chunk)
        email_embedding = get_document_embedding(doc.id, repo)

        # 3. Match interests
        interests = load_interests(repo)
        interest_matches =
          if email_embedding do
            InterestMatcher.match_interests(email_embedding, interests,
              threshold: state.interest_threshold
            )
          else
            # Keyword fallback
            InterestMatcher.keyword_match(doc.raw_text || "", interests)
            |> Enum.map(fn m -> %{topic: m.topic, score: 0.6} end)
          end

        # 4. Classify (fast path first, then LLM fallback)
        sender_name = doc.source_metadata["sender_name"] || ""
        sender_addr = doc.source_metadata["sender"] || ""
        from_field = if sender_name != "", do: "#{sender_name} <#{sender_addr}>", else: sender_addr

        fast_email = %{
          from: from_field,
          subject: doc.title || "",
          labels: doc.source_metadata["labels"] || []
        }

        email = %{
          subject: doc.title || "",
          body_text: doc.raw_text || "",
          from: %{email: sender_addr, name: doc.source_metadata["sender_name"]}
        }

        context = %{
          sender_info: sender_info,
          interest_matches: interest_matches
        }

        {classification_result, sender_type} =
          case FastClassifier.classify(fast_email, repo: state.repo) do
            {:ok, %{sender_type: st} = classification} ->
              {{:ok, classification}, st}

            {:no_match, %{sender_type: st}} ->
              # Thread sender_type into the LLM fallback context per spec §4.2:
              # even when the category cascade exhausts, sender_type is computed
              # and must reach the downstream classifier.
              context_with_sender = Map.put(context, :sender_type, st)
              {state.classifier_fn.(email, context: context_with_sender), st}
          end

        case classification_result do
          {:ok, classification} ->
            # 5. Score priority
            final_priority =
              PriorityScorer.score(%{
                classification_priority: classification.priority,
                sender_priority_score: sender_info.priority_score,
                is_priority_sender: sender_info.is_priority,
                interest_scores: Enum.map(interest_matches, & &1.score),
                thread_has_priority_senders: false
              })

            # 6. Step 10: TriageRecord write + Enricher enqueue inside a
            # Repo.transaction. kb_feedback stays independent below per the
            # audit-confirmed "tight transaction" shape (option A).
            write_triage_record_and_enqueue(doc, classification, sender_type, repo)

            # 7. Map category to Gmail label
            label = label_for_category(classification.category)

            # 8. Mark read + label in Gmail (except high-priority personal)
            apply_gmail_actions(doc, classification, final_priority, label, state)

            # 9. Record triage feedback (kb_feedback dual write — independent
            # of the TriageRecord transaction above)
            record_triage_feedback(repo, doc.id, %{
              category: classification.category,
              final_priority: final_priority,
              source: Map.get(classification, :source, :llm)
            })

            [%{
              document_id: doc.id,
              classification: Map.put(classification, :interest_matches, interest_matches),
              sender_info: sender_info,
              subject: doc.title,
              final_priority: final_priority
            }]

          {:error, reason} ->
            sender_addr = doc.source_metadata["sender"] || "unknown"
            Logger.warning("[EmailTriage] Classification failed for #{sender_addr} — #{doc.title}: #{inspect(reason)}")

            record_triage_feedback(repo, doc.id, %{
              error: inspect(reason)
            })

            []
        end
    end
  end

  defp lookup_sender(doc, repo) do
    sender_email = doc.source_metadata["sender"]

    case sender_email && repo.one(from(s in EmailSender, where: s.email == ^sender_email)) do
      nil ->
        %{email: sender_email, name: nil, is_priority: false, priority_score: 0.0}

      sender ->
        %{
          email: sender.email,
          name: sender.name,
          is_priority: sender.is_priority,
          priority_score: sender.priority_score
        }
    end
  end

  defp get_document_embedding(doc_id, repo) do
    case repo.one(
           from(c in Chunk,
             where: c.document_id == ^doc_id and not is_nil(c.embedding),
             order_by: [asc: c.chunk_index],
             limit: 1
           )
         ) do
      nil -> nil
      chunk -> Pgvector.to_list(chunk.embedding)
    end
  end

  defp load_interests(repo) do
    repo.all(from(i in Interest, where: i.enabled == true))
    |> Enum.map(fn i ->
      %{
        topic: i.topic,
        keywords: i.keywords,
        weight: i.weight,
        embedding: if(i.embedding, do: Pgvector.to_list(i.embedding), else: nil),
        enabled: i.enabled
      }
    end)
  end

  defp send_notifications(results, state) do
    if state.telegram_fn do
      {high, low} =
        Enum.split_with(results, fn r -> r.final_priority >= state.high_priority_threshold end)

      # High priority: individual messages
      Enum.each(high, fn result ->
        text = TelegramFormatter.format_high_priority(result)
        state.telegram_fn.(nil, text, [])
      end)

      # Low priority: batch digest
      case TelegramFormatter.format_digest(low) do
        nil -> :ok
        text -> state.telegram_fn.(nil, text, [])
      end
    end
  end

  defp apply_gmail_actions(doc, classification, final_priority, label, state) do
    if state.gmail_fn do
      try do
        message_id = doc.source_id
        keep_unread = final_priority >= state.high_priority_threshold and
                      classification.category in ["personal", "business"]

        opts = [add: [label]]
        opts = if keep_unread, do: opts, else: Keyword.put(opts, :remove, ["UNREAD"])

        state.gmail_fn.(nil, message_id, opts)
      rescue
        e ->
          Logger.warning("[EmailTriage] Gmail action failed for #{doc.source_id}: #{inspect(e)}")
          :ok
      end
    end
  end

  # Map classification categories to Gmail labels
  defp label_for_category("business"), do: "Kerf/Business"
  defp label_for_category("personal"), do: "Kerf/Personal"
  defp label_for_category("newsletter"), do: "Kerf/Newsletter"
  defp label_for_category("transactional"), do: "Kerf/Transactional"
  defp label_for_category("marketing"), do: "Kerf/Marketing"
  defp label_for_category("social"), do: "Kerf/Social"
  defp label_for_category("spam"), do: "Kerf/Spam"
  defp label_for_category(_), do: "Kerf/Triaged"

  # Step 10: atomic TriageRecord write + Enricher enqueue.
  # On transaction failure, log and continue — the caller-visible return shape
  # (an entry in the results list) must be preserved per the Step 10 audit.
  defp write_triage_record_and_enqueue(doc, classification, sender_type, repo) do
    classify_attrs = %{
      document_id: doc.id,
      category: classification.category,
      sender_type: sender_type,
      classifier_source: classifier_source_str(classification),
      confidence: Map.get(classification, :confidence)
    }

    result =
      repo.transaction(fn ->
        record =
          (repo.get_by(TriageRecord, document_id: doc.id) || %TriageRecord{})
          |> TriageRecord.classify_changeset(classify_attrs)
          |> repo.insert_or_update!()

        # unique: false — this call site is always operator-deliberate (live
        # triage, manual re-triage, backfill). The worker-level dedup window
        # protects against unintended retry loops elsewhere; explicit bypass
        # here is the contract.
        %{triage_record_id: record.id, enrichment_version: 1}
        |> Enricher.new(unique: false)
        |> Oban.insert!()

        record
      end)

    case result do
      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[EmailTriage] TriageRecord write failed for #{doc.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp classifier_source_str(classification) do
    case Map.get(classification, :source, :llm) do
      :fast_classifier -> "fast_classifier"
      _ -> "llm_classifier"
    end
  end

  @doc """
  SPEC C Part 3 — RED skeleton. Upsert-replace the triage-type `kb_feedback` for
  a document: clear prior `feedback_type = "triage"` rows for `document_id`, then
  insert the new record (decision derived from `context`, as `record_triage_feedback/3`
  does). Result: exactly one triage feedback row per doc; a successful retry
  overwrites a prior error breadcrumb. The clear is scoped to triage feedback of
  that one document — other feedback types and other documents are untouched.

  Raises until GREEN — present only so the RED suite compiles.
  """
  def upsert_triage_feedback(_repo, _document_id, _context) do
    raise "Kerf.Agents.EmailTriage.EmailTriage.upsert_triage_feedback/3 not implemented (RED — SPEC C Part 3)"
  end

  defp record_triage_feedback(repo, document_id, context) do
    decision = if Map.has_key?(context, :error), do: "unclassified", else: "classified"

    try do
      %Feedback{}
      |> Feedback.changeset(%{
        document_id: document_id,
        feedback_type: "triage",
        decision: decision,
        context: Map.new(context, fn {k, v} -> {to_string(k), v} end),
        source: "system"
      })
      |> repo.insert!()
    rescue
      e ->
        Logger.warning("[EmailTriage] Failed to record feedback for #{document_id}: #{inspect(e)}")
    end
  end

  defp default_classifier(email, opts) do
    Classifier.classify(email, opts)
  end
end
