defmodule Kerf.Agents.EmailTriage.InterestMatcherTest do
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.InterestMatcher

  # Helper: create a normalized vector pointing mostly in one direction
  defp make_vector(dominant_index, dims \\ 1024) do
    v = List.duplicate(0.0, dims) |> List.replace_at(dominant_index, 1.0)
    norm = :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(v, &(&1 / norm))
  end

  describe "cosine_similarity/2" do
    test "identical vectors return 1.0" do
      v = make_vector(0)
      assert_in_delta InterestMatcher.cosine_similarity(v, v), 1.0, 0.001
    end

    test "orthogonal vectors return 0.0" do
      v1 = make_vector(0)
      v2 = make_vector(1)
      assert_in_delta InterestMatcher.cosine_similarity(v1, v2), 0.0, 0.001
    end

    test "similar vectors return high score" do
      v1 = [0.9, 0.1, 0.0] ++ List.duplicate(0.0, 765)
      v2 = [0.8, 0.2, 0.0] ++ List.duplicate(0.0, 765)
      sim = InterestMatcher.cosine_similarity(v1, v2)
      assert sim > 0.9
    end
  end

  describe "match_interests/3" do
    test "returns matching interests above threshold" do
      email_embedding = make_vector(0)

      interests = [
        %{topic: "AI/ML", embedding: make_vector(0), keywords: [], weight: 1.0, enabled: true},
        %{topic: "Security", embedding: make_vector(1), keywords: [], weight: 1.0, enabled: true}
      ]

      matches = InterestMatcher.match_interests(email_embedding, interests, threshold: 0.5)
      assert length(matches) == 1
      assert hd(matches).topic == "AI/ML"
      assert hd(matches).score > 0.9
    end

    test "returns top-N matches" do
      email_embedding = [0.5, 0.5, 0.5] ++ List.duplicate(0.0, 765)

      interests = [
        %{topic: "A", embedding: [0.6, 0.4, 0.5] ++ List.duplicate(0.0, 765), keywords: [], weight: 1.0, enabled: true},
        %{topic: "B", embedding: [0.5, 0.6, 0.4] ++ List.duplicate(0.0, 765), keywords: [], weight: 1.0, enabled: true},
        %{topic: "C", embedding: [0.4, 0.5, 0.6] ++ List.duplicate(0.0, 765), keywords: [], weight: 1.0, enabled: true}
      ]

      matches = InterestMatcher.match_interests(email_embedding, interests, threshold: 0.0, max_matches: 2)
      assert length(matches) == 2
    end

    test "skips disabled interests" do
      email_embedding = make_vector(0)

      interests = [
        %{topic: "Disabled", embedding: make_vector(0), keywords: [], weight: 1.0, enabled: false}
      ]

      matches = InterestMatcher.match_interests(email_embedding, interests, threshold: 0.0)
      assert matches == []
    end

    test "returns empty for no interests" do
      matches = InterestMatcher.match_interests(make_vector(0), [], threshold: 0.5)
      assert matches == []
    end

    test "skips interests without embeddings" do
      email_embedding = make_vector(0)

      interests = [
        %{topic: "NoEmbed", embedding: nil, keywords: ["test"], weight: 1.0, enabled: true}
      ]

      matches = InterestMatcher.match_interests(email_embedding, interests, threshold: 0.5)
      assert matches == []
    end

    test "applies weight multiplier to score" do
      email_embedding = make_vector(0)

      interests = [
        %{topic: "High", embedding: make_vector(0), keywords: [], weight: 2.0, enabled: true},
        %{topic: "Low", embedding: make_vector(0), keywords: [], weight: 0.5, enabled: true}
      ]

      matches = InterestMatcher.match_interests(email_embedding, interests, threshold: 0.0)
      high = Enum.find(matches, &(&1.topic == "High"))
      low = Enum.find(matches, &(&1.topic == "Low"))
      assert high.score > low.score
    end
  end

  describe "keyword_match/2" do
    test "matches keywords in text" do
      interests = [
        %{topic: "AI/ML", keywords: ["machine learning", "LLM", "neural network"], enabled: true},
        %{topic: "Rust", keywords: ["rust", "cargo", "crate"], enabled: true}
      ]

      matches = InterestMatcher.keyword_match("New paper on machine learning and LLM training", interests)
      assert length(matches) == 1
      assert hd(matches).topic == "AI/ML"
      assert hd(matches).matched_keywords == ["machine learning", "LLM"]
    end

    test "case-insensitive matching" do
      interests = [
        %{topic: "Elixir", keywords: ["elixir", "OTP"], enabled: true}
      ]

      matches = InterestMatcher.keyword_match("Learning ELIXIR and otp", interests)
      assert length(matches) == 1
    end

    test "skips disabled interests" do
      interests = [
        %{topic: "Off", keywords: ["test"], enabled: false}
      ]

      assert InterestMatcher.keyword_match("test", interests) == []
    end

    test "returns empty for no keyword matches" do
      interests = [
        %{topic: "AI", keywords: ["neural", "deep learning"], enabled: true}
      ]

      assert InterestMatcher.keyword_match("unrelated topic about cooking", interests) == []
    end
  end
end
