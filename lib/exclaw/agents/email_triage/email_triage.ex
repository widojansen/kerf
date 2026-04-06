defmodule ExClaw.Agents.EmailTriage.EmailTriage do
  @moduledoc """
  Classifies new emails, scores priority, generates summaries,
  and surfaces results to Telegram with approval buttons.
  """
  use GenServer
  require Logger

  alias ExClaw.KnowledgeBase.{Document, Chunk, EmailSender, Feedback, Interest}
  alias ExClaw.Agents.EmailTriage.{Classifier, FastClassifier, PriorityScorer, InterestMatcher, TelegramFormatter}

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
      gmail_label: Keyword.get(opts, :gmail_label, "ExClaw/Triaged"),
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
      |> Enum.flat_map(fn doc_id -> triage_document(doc_id, state) end)

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

        classification_result =
          case FastClassifier.classify(fast_email, repo: state.repo) do
            {:ok, _} = fast -> fast
            :no_match -> state.classifier_fn.(email, context: context)
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

            # 6. Map category to Gmail label
            label = label_for_category(classification.category)

            # 7. Mark read + label in Gmail (except high-priority personal)
            apply_gmail_actions(doc, classification, final_priority, label, state)

            # 8. Record triage feedback
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
  defp label_for_category("business"), do: "ExClaw/Business"
  defp label_for_category("personal"), do: "ExClaw/Personal"
  defp label_for_category("newsletter"), do: "ExClaw/Newsletter"
  defp label_for_category("transactional"), do: "ExClaw/Transactional"
  defp label_for_category("marketing"), do: "ExClaw/Marketing"
  defp label_for_category("social"), do: "ExClaw/Social"
  defp label_for_category("spam"), do: "ExClaw/Spam"
  defp label_for_category(_), do: "ExClaw/Triaged"

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
