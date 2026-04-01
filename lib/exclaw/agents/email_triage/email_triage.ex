defmodule ExClaw.Agents.EmailTriage.EmailTriage do
  @moduledoc """
  Classifies new emails, scores priority, generates summaries,
  and surfaces results to Telegram with approval buttons.
  """
  use GenServer

  alias ExClaw.KnowledgeBase.{Document, Chunk, EmailSender, Interest}
  alias ExClaw.Agents.EmailTriage.{Classifier, PriorityScorer, InterestMatcher, TelegramFormatter}

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

        # 4. Classify
        email = %{
          subject: doc.title || "",
          body_text: doc.raw_text || "",
          from: %{
            email: doc.source_metadata["sender"] || "",
            name: doc.source_metadata["sender_name"]
          }
        }

        context = %{
          sender_info: sender_info,
          interest_matches: interest_matches
        }

        case state.classifier_fn.(email, context: context) do
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

            [%{
              document_id: doc.id,
              classification: Map.put(classification, :interest_matches, interest_matches),
              sender_info: sender_info,
              subject: doc.title,
              final_priority: final_priority
            }]

          {:error, _reason} ->
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

  defp default_classifier(email, opts) do
    Classifier.classify(email, opts)
  end
end
