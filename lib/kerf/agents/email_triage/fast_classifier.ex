defmodule Kerf.Agents.EmailTriage.FastClassifier do
  @moduledoc """
  Deterministic pre-LLM classifier. Two concerns, computed independently per call:

    * **category cascade** (existing) — checks `email_senders` for known patterns
      and Gmail category labels to assign a category. Returns `{:ok, classification}`
      on match or `:no_match` on cascade exhaustion (internal sentinel).

    * **sender_type derivation** (Step 3, Email Triage Enrichment spec §4.2) —
      classifies the sender into one of four buckets, run on every call regardless
      of category-cascade outcome. The four values:

        - `known_priority`   — `email_senders` row with `priority_override IS NOT NULL`,
                               matched by exact email
        - `automated_system` — From-header local part starts with one of
                               `@automated_prefixes` (noreply, mailer-daemon, …)
        - `known_routine`    — `email_senders` row with `total_emails >= 3`,
                               matched by exact email
        - `unknown_human`    — none of the above

  Public API:

      classify(email, opts) ::
        {:ok, classification_with_sender_type}
        | {:no_match, %{sender_type: String.t()}}

  `marketing_list` (a fifth sender_type from spec §2.2) is deferred until the
  `List-Unsubscribe` header is surfaced into `kb_documents.source_metadata`.
  """

  alias Kerf.Agents.EmailTriage.FastClassifier.Cache
  alias Kerf.KnowledgeBase.EmailSender
  import Ecto.Query

  @automated_prefixes ~w(
    noreply
    no-reply
    donotreply
    do-not-reply
    mailer-daemon
    bounce
    bounces
  )

  @valid_sender_types ~w(known_priority known_routine automated_system unknown_human)

  @doc """
  Attempt deterministic classification of an email.

  Category cascade (in order):
    1. Exact email match in `email_senders` with classification_override set
    2. `match_pattern` substring match against From field
    3. Domain match against sender domain
    4. Gmail category header mapping (CATEGORY_PROMOTIONS, etc.)

  Independently, `sender_type` is derived per spec §4.2 cascade. `sender_type`
  is returned in BOTH the `{:ok, classification}` and the `{:no_match, ...}` paths.

  Uses the ETS cache for category-cascade lookups when `:cache` is provided.
  The sender_type derivation always queries via `:repo` (uncached) — small
  cost at our volume (~235 emails/day).

  Returns:
    * `{:ok, classification}` where `classification` includes `:sender_type`
    * `{:no_match, %{sender_type: sender_type}}`
  """
  def classify(%{from: from} = email, opts \\ []) do
    cache = Keyword.get(opts, :cache)
    repo = Keyword.get(opts, :repo, Kerf.Repo)
    sender_email = extract_email(from)
    sender_domain = extract_domain(sender_email)

    sender_type = derive_sender_type(sender_email, repo)

    category_result =
      with :no_match <- match_by_email(cache, repo, sender_email),
           :no_match <- match_by_pattern(cache, repo, from),
           :no_match <- match_by_domain(cache, repo, sender_domain),
           :no_match <- match_by_gmail_category(email) do
        :no_match
      end

    case category_result do
      {:ok, classification} -> {:ok, Map.put(classification, :sender_type, sender_type)}
      :no_match -> {:no_match, %{sender_type: sender_type}}
    end
  end

  # --- sender_type derivation (cascade) ---

  defp derive_sender_type(sender_email, repo) do
    cond do
      derive_known_priority(sender_email, repo) -> "known_priority"
      derive_automated_system(sender_email) -> "automated_system"
      derive_known_routine(sender_email, repo) -> "known_routine"
      true -> "unknown_human"
    end
  end

  defp derive_known_priority(sender_email, repo) do
    query =
      from s in EmailSender,
        where: s.email == ^sender_email and not is_nil(s.priority_override),
        limit: 1

    repo.one(query) != nil
  end

  defp derive_automated_system(sender_email) do
    case String.split(sender_email, "@", parts: 2) do
      [local, _domain] -> Enum.any?(@automated_prefixes, &String.starts_with?(local, &1))
      _ -> false
    end
  end

  defp derive_known_routine(sender_email, repo) do
    query =
      from s in EmailSender,
        where: s.email == ^sender_email and s.total_emails >= 3,
        limit: 1

    repo.one(query) != nil
  end

  # --- category cascade (unchanged) ---

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

  # --- helpers ---

  @doc false
  def valid_sender_types, do: @valid_sender_types

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
