defmodule Kerf.LLM.Enrich do
  @moduledoc """
  Adapter for the email enrichment LLM call (Step 5 of Email Triage Enrichment).

  Pure module — no DB, no state. Responsibilities:

    * Build the enrichment prompt from an input map (per `Kerf.Agents.EmailTriage.Classifier`
      prompt-style conventions, adapted for the tool-call enrichment task)
    * Build the OpenAI-compatible tool spec via `Kerf.Agents.EmailTriage.ToolSpec.build/2`
    * Call the provider with `tools: [...]` and `tool_choice: {type: function, ...}`
    * Parse the resulting tool_call args into the structured enrichment result
    * Compute off-taxonomy proposals (topic/action values not in the accepted lists)
    * Pass the value through verbatim into the result (permissive on off-taxonomy)

  The adapter does not write to the DB. The Enricher worker is responsible for
  persisting the result and recording proposals via `Taxonomy.record_proposal/3`.

  Body truncation is the worker's responsibility, not the adapter's. The
  adapter passes `body_text` through verbatim; if it is nil/empty, the adapter
  synthesises a body from `source_metadata` (subject + sender + labels).
  """

  alias Kerf.Agents.EmailTriage.ToolSpec

  @default_model "nemotron-cascade-2"

  @sender_type_glosses %{
    "known_priority" => "this sender is on the user's priority list",
    "known_routine" => "this sender is familiar but not flagged as priority",
    "unknown_human" => "new sender, looks like a real person",
    "automated_system" => "automated/bot sender"
  }

  @type input :: %{
          required(:from) => %{
            required(:email) => String.t() | nil,
            required(:name) => String.t() | nil
          },
          required(:subject) => String.t(),
          required(:body_text) => String.t() | nil,
          required(:sender_type) => String.t(),
          required(:source_metadata) => map()
        }

  @type result :: %{
          urgency: String.t(),
          action: String.t(),
          topic: [String.t()],
          summary: String.t(),
          proposals: %{topic: [String.t()], action: [String.t()]}
        }

  @spec enrich(input(), keyword()) :: {:ok, result()} | {:error, term()}
  def enrich(input, opts) do
    provider_fn = Keyword.get(opts, :provider_fn, &default_provider/3)
    accepted_topics = Keyword.fetch!(opts, :accepted_topics)
    accepted_actions = Keyword.fetch!(opts, :accepted_actions)
    temperature = Keyword.get(opts, :temperature)
    model = Keyword.get(opts, :model, @default_model)

    tool_spec = ToolSpec.build(accepted_topics, accepted_actions)
    prompt = build_prompt(input)
    messages = [%{role: "user", content: prompt}]

    provider_opts =
      [
        tools: [tool_spec],
        tool_choice: %{type: "function", function: %{name: "enrich_email"}}
      ]
      |> maybe_put(:temperature, temperature)

    case provider_fn.(model, messages, provider_opts) do
      {:ok, %{type: :tool_use, calls: [%{input: args} | _]}} ->
        {:ok, build_result(args, accepted_topics, accepted_actions)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  # ---------- result + proposal extraction ----------

  defp build_result(args, accepted_topics, accepted_actions) do
    topic = Map.get(args, "topic", [])
    action = Map.get(args, "action")

    topic_set = MapSet.new(accepted_topics)
    action_set = MapSet.new(accepted_actions)

    # Order-preserving: filter retains the order of `topic` as the LLM
    # returned it. Sorting would lose the LLM's primary-vs-secondary signal.
    topic_proposals = Enum.filter(topic, fn t -> not MapSet.member?(topic_set, t) end)

    action_proposals =
      cond do
        is_nil(action) -> []
        MapSet.member?(action_set, action) -> []
        true -> [action]
      end

    %{
      urgency: Map.get(args, "urgency"),
      action: action,
      topic: topic,
      summary: Map.get(args, "summary", ""),
      proposals: %{topic: topic_proposals, action: action_proposals}
    }
  end

  # ---------- prompt construction ----------

  defp build_prompt(input) do
    sender_email =
      get_in(input, [:from, :email]) || input.source_metadata["sender"] || ""

    sender_name =
      get_in(input, [:from, :name]) || input.source_metadata["sender_name"] || ""

    sender_type = Map.get(input, :sender_type, "unknown_human")
    gloss = Map.get(@sender_type_glosses, sender_type, "")

    # Defensive subject read — :title path is the primary source from the
    # worker, but if the worker's input map somehow has a nil subject, fall
    # back to source_metadata["subject"] then "".
    subject = input.subject || input.source_metadata["subject"] || ""

    body = body_or_fallback(input)

    """
    /no_think
    Classify this email and label it with urgency, action, topic(s), and a one-sentence summary. Use the curated vocabularies in the function description where they fit; propose new values only when no existing value applies. Write the summary in the same language as the email body.

    From: #{sender_name} <#{sender_email}>
    Sender type: #{sender_type} (#{gloss})
    Subject: #{subject}

    Body:
    #{body}
    """
  end

  defp body_or_fallback(%{body_text: text} = input) when is_binary(text) do
    if String.trim(text) == "" do
      synthetic_body(input)
    else
      text
    end
  end

  defp body_or_fallback(input), do: synthetic_body(input)

  defp synthetic_body(input) do
    name = input.source_metadata["sender_name"] || "unknown sender"
    sender = input.source_metadata["sender"] || "unknown address"
    labels = input.source_metadata["labels"] || []

    labels_str =
      case labels do
        [] -> "no Gmail labels"
        list when is_list(list) -> Enum.join(list, ", ")
        _ -> "no Gmail labels"
      end

    "[No body text available. This email is from #{name} <#{sender}>, labeled by Gmail as #{labels_str}.]"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Wraps VLLMProvider.complete/4 into the 3-arg provider_fn contract
  # `(model, messages, opts) -> {:ok, response} | {:error, reason}`.
  # Capturing &VLLMProvider.complete/3 directly resolves to
  # `complete(name, model, messages)` (first arg taken as GenServer name)
  # because of complete's default-arg head — see complete/2..4 in vllm_provider.ex.
  defp default_provider(model, messages, opts) do
    Kerf.LLM.VLLMProvider.complete(Kerf.LLM.VLLMProvider, model, messages, opts)
  end
end
