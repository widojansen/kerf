defmodule ExClaw.Agents.EmailTriage.InterestMatcher do
  @moduledoc """
  Semantic and keyword-based interest matching for email triage.
  """

  @doc """
  Compute cosine similarity between two vectors.
  """
  def cosine_similarity(v1, v2) when is_list(v1) and is_list(v2) do
    dot = Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(v1, 0.0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(v2, 0.0, fn x, acc -> acc + x * x end))

    if norm1 == 0.0 or norm2 == 0.0, do: 0.0, else: dot / (norm1 * norm2)
  end

  @doc """
  Match an email embedding against a list of interest embeddings.
  Returns sorted matches above the threshold.

  Options:
    - `:threshold` — minimum cosine similarity (default 0.5)
    - `:max_matches` — max number of results (default 3)
  """
  def match_interests(email_embedding, interests, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.5)
    max_matches = Keyword.get(opts, :max_matches, 3)

    interests
    |> Enum.filter(&(&1.enabled && &1.embedding != nil))
    |> Enum.map(fn interest ->
      raw_score = cosine_similarity(email_embedding, interest.embedding)
      weighted_score = raw_score * interest.weight

      %{topic: interest.topic, score: weighted_score, raw_score: raw_score}
    end)
    |> Enum.filter(&(&1.raw_score >= threshold))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(max_matches)
  end

  @doc """
  Keyword fallback matching. Returns interests whose keywords appear in the text.
  """
  def keyword_match(text, interests) do
    text_down = String.downcase(text)

    interests
    |> Enum.filter(& &1.enabled)
    |> Enum.flat_map(fn interest ->
      matched =
        (interest.keywords || [])
        |> Enum.filter(fn kw -> String.contains?(text_down, String.downcase(kw)) end)

      if matched != [] do
        [%{topic: interest.topic, matched_keywords: matched}]
      else
        []
      end
    end)
  end
end
