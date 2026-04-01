defmodule ExClaw.Agents.EmailTriage.PriorityScorer do
  @moduledoc """
  Combines classification priority, sender score, interest matches,
  and thread context into a final priority score (1-5).
  """

  @doc """
  Calculate final priority score from multiple signals.

  Input map:
    - `:classification_priority` — LLM-assigned priority (1-5)
    - `:sender_priority_score` — sender's learned score (-1.0 to 1.0)
    - `:is_priority_sender` — boolean
    - `:interest_scores` — list of interest match scores
    - `:thread_has_priority_senders` — boolean
  """
  def score(signals) do
    base = signals.classification_priority

    sender_boost =
      cond do
        signals.is_priority_sender -> 1.0
        signals.sender_priority_score > 0.5 -> 0.5
        signals.sender_priority_score < -0.5 -> -0.5
        true -> 0.0
      end

    interest_boost =
      case signals.interest_scores do
        [] -> 0.0
        scores ->
          avg = Enum.sum(scores) / length(scores)
          if avg > 0.6, do: 1.0, else: avg
      end

    thread_boost =
      if signals.thread_has_priority_senders, do: 0.5, else: 0.0

    raw = base + sender_boost + interest_boost + thread_boost

    raw
    |> round()
    |> max(1)
    |> min(5)
  end
end
