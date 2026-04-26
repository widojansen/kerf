defmodule Kerf.Agents.EmailTriage.PriorityScorerTest do
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.PriorityScorer

  describe "score/1" do
    test "high priority sender boosts score" do
      result =
        PriorityScorer.score(%{
          classification_priority: 3,
          sender_priority_score: 0.9,
          is_priority_sender: true,
          interest_scores: [],
          thread_has_priority_senders: false
        })

      assert result >= 4
    end

    test "strong interest match boosts score" do
      result =
        PriorityScorer.score(%{
          classification_priority: 2,
          sender_priority_score: 0.0,
          is_priority_sender: false,
          interest_scores: [0.9, 0.8],
          thread_has_priority_senders: false
        })

      assert result >= 3
    end

    test "thread with priority senders boosts score" do
      result =
        PriorityScorer.score(%{
          classification_priority: 2,
          sender_priority_score: 0.0,
          is_priority_sender: false,
          interest_scores: [],
          thread_has_priority_senders: true
        })

      assert result > 2
    end

    test "base score is classification priority" do
      result =
        PriorityScorer.score(%{
          classification_priority: 3,
          sender_priority_score: 0.0,
          is_priority_sender: false,
          interest_scores: [],
          thread_has_priority_senders: false
        })

      assert result == 3
    end

    test "score is clamped to 1-5 range" do
      high =
        PriorityScorer.score(%{
          classification_priority: 5,
          sender_priority_score: 1.0,
          is_priority_sender: true,
          interest_scores: [1.0, 1.0, 1.0],
          thread_has_priority_senders: true
        })

      low =
        PriorityScorer.score(%{
          classification_priority: 1,
          sender_priority_score: -1.0,
          is_priority_sender: false,
          interest_scores: [],
          thread_has_priority_senders: false
        })

      assert high == 5
      assert low == 1
    end
  end
end
