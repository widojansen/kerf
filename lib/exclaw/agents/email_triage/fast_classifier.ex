defmodule ExClaw.Agents.EmailTriage.FastClassifier do
  @moduledoc """
  Deterministic pre-LLM classifier. Checks email_senders for known patterns
  and classification overrides before falling through to LLM classification.

  Returns {:ok, classification_map} if a deterministic match is found,
  or :no_match to signal the caller should use the LLM Classifier.
  """

  alias ExClaw.Agents.EmailTriage.FastClassifier.Cache
  alias ExClaw.KnowledgeBase.EmailSender
  import Ecto.Query

  @doc """
  Attempt deterministic classification of an email.

  Checks in order:
  1. Exact email match in email_senders with classification_override set
  2. match_pattern substring match against from field
  3. domain match against sender domain
  4. Gmail category header mapping (CATEGORY_PROMOTIONS, etc.)

  Uses ETS cache when a `:cache` option is provided, otherwise falls back
  to direct Repo queries.

  Returns {:ok, classification} or :no_match.
  """
  def classify(%{from: from} = email, opts \\ []) do
    cache = Keyword.get(opts, :cache)
    repo = Keyword.get(opts, :repo, ExClaw.Repo)
    sender_email = extract_email(from)
    sender_domain = extract_domain(sender_email)

    with :no_match <- match_by_email(cache, repo, sender_email),
         :no_match <- match_by_pattern(cache, repo, from),
         :no_match <- match_by_domain(cache, repo, sender_domain),
         :no_match <- match_by_gmail_category(email) do
      :no_match
    end
  end

  # --- Match functions ---

  defp match_by_email(cache, repo, email) do
    if cache do
      case Cache.get_by_email(cache, email) do
        {:ok, sender} -> {:ok, build_classification(sender)}
        :no_match -> :no_match
      end
    else
      query =
        from s in EmailSender,
          where: s.email == ^email and not is_nil(s.classification_override),
          limit: 1

      case repo.one(query) do
        nil -> :no_match
        sender -> {:ok, build_classification(sender)}
      end
    end
  end

  defp match_by_pattern(cache, repo, from_field) do
    from_lower = String.downcase(from_field)

    rules =
      if cache do
        Cache.get_pattern_rules(cache)
      else
        from(s in EmailSender,
          where: not is_nil(s.match_pattern) and not is_nil(s.classification_override),
          order_by: [desc: s.priority_override]
        )
        |> repo.all()
      end

    rules
    |> Enum.find(fn sender ->
      String.contains?(from_lower, String.downcase(sender.match_pattern))
    end)
    |> case do
      nil -> :no_match
      sender -> {:ok, build_classification(sender)}
    end
  end

  defp match_by_domain(cache, repo, domain) do
    if cache do
      case Cache.get_by_domain(cache, domain) do
        {:ok, sender} -> {:ok, build_classification(sender)}
        :no_match -> :no_match
      end
    else
      query =
        from s in EmailSender,
          where: s.domain == ^domain and not is_nil(s.classification_override),
          limit: 1

      case repo.one(query) do
        nil -> :no_match
        sender -> {:ok, build_classification(sender)}
      end
    end
  end

  defp match_by_gmail_category(%{labels: labels}) when is_list(labels) do
    cond do
      "CATEGORY_PROMOTIONS" in labels ->
        {:ok, %{
          category: "marketing",
          priority: 1,
          summary: "Promotional email (Gmail category)",
          action: "archive",
          confidence: 0.9,
          source: :fast_classifier
        }}

      "CATEGORY_SOCIAL" in labels ->
        {:ok, %{
          category: "social",
          priority: 1,
          summary: "Social notification (Gmail category)",
          action: "archive",
          confidence: 0.85,
          source: :fast_classifier
        }}

      "CATEGORY_UPDATES" in labels ->
        {:ok, %{
          category: "transactional",
          priority: 2,
          summary: "Update notification (Gmail category)",
          action: "archive",
          confidence: 0.8,
          source: :fast_classifier
        }}

      "CATEGORY_FORUMS" in labels ->
        {:ok, %{
          category: "newsletter",
          priority: 1,
          summary: "Forum/mailing list (Gmail category)",
          action: "archive",
          confidence: 0.8,
          source: :fast_classifier
        }}

      true -> :no_match
    end
  end
  defp match_by_gmail_category(_), do: :no_match

  # --- Helpers ---

  defp build_classification(%EmailSender{} = sender) do
    %{
      category: sender.classification_override,
      priority: sender.priority_override || default_priority(sender.classification_override),
      summary: "Known sender: #{sender.name || sender.email} (#{sender.classification_override})",
      action: default_action(sender.classification_override),
      confidence: 1.0,
      source: :fast_classifier
    }
  end

  defp default_priority("newsletter"), do: 1
  defp default_priority("marketing"), do: 1
  defp default_priority("spam"), do: 1
  defp default_priority("transactional"), do: 2
  defp default_priority("social"), do: 1
  defp default_priority("personal"), do: 3
  defp default_priority("business"), do: 3
  defp default_priority(_), do: 2

  defp default_action("newsletter"), do: "archive"
  defp default_action("marketing"), do: "archive"
  defp default_action("spam"), do: "ignore"
  defp default_action("transactional"), do: "archive"
  defp default_action("social"), do: "archive"
  defp default_action("personal"), do: "follow_up"
  defp default_action("business"), do: "follow_up"
  defp default_action(_), do: "archive"

  defp extract_email(from) do
    case Regex.run(~r/<([^>]+)>/, from) do
      [_, email] -> String.downcase(email)
      _ -> String.downcase(String.trim(from))
    end
  end

  defp extract_domain(email) do
    case String.split(email, "@") do
      [_, domain] -> domain
      _ -> ""
    end
  end
end
