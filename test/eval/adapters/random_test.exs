defmodule Kerf.Eval.Adapters.RandomTest do
  @moduledoc """
  SPEC_H F09.9 / F09.6 — the known-bad adapter, always called through
  Kerf.Decide.ask/3 (plan 2.6), so `{:ok, _}` means Decide's own schema checks
  (labels, probabilities summing to 1 ± 1e-3, Score ranges) accepted every
  answer. Randomness comes from `opts[:harness_seed]`, the 3-tuple
  `:rand.seed/2` accepts (A3.11).
  """
  use ExUnit.Case, async: true

  alias Kerf.Decide
  alias Kerf.Decide.{OptionSet, Question, State}
  alias Kerf.Eval.Adapters.Random

  @categories ~w(business personal newsletter transactional spam social)
  @levels ~w(1 2 3 4 5)

  defp state do
    %State{
      content: "From: user1@example.invalid\nSubject: Test\nDate: 2026-10-20\n\nBody",
      provenance: %{taint: :tainted, origin: :ingress, sources: ["it-0001"]}
    }
  end

  defp questions do
    [
      Question.choice(:category, "Which category?", OptionSet.new!(@categories)),
      Question.noul(:needs_reply, "Does this email need a reply?"),
      Question.score(:urgency, "How urgent?", @levels),
      Question.noul(:deadline_present, "Is there a deadline?"),
      Question.choice(:client, "Which client?", OptionSet.new!(~w(client-a client-b none)))
    ]
  end

  defp ask(seed, qs \\ questions()) do
    Decide.ask(state(), qs, adapter: Random, harness_seed: seed)
  end

  defp without_latency(results),
    do: Map.new(results, fn {name, result} -> {name, Map.delete(result, :latency_ms)} end)

  test "answers every question through Decide.ask/3 with in-schema results" do
    assert {:ok, results} = ask({1, 64, 0})

    assert results |> Map.keys() |> Enum.sort() ==
             [:category, :client, :deadline_present, :needs_reply, :urgency]
  end

  test "Noul result has p_yes in [0, 1]" do
    {:ok, %{needs_reply: result}} = ask({1, 64, 0})

    assert result.p_yes >= 0 and result.p_yes <= 1
  end

  test "Choice result picks a label from the caller's options, probs in the caller's order" do
    {:ok, %{category: result}} = ask({1, 64, 0})

    assert result.label in @categories
    assert Enum.map(result.probs, &elem(&1, 0)) == @categories
    assert_in_delta result.probs |> Enum.map(&elem(&1, 1)) |> Enum.sum(), 1.0, 1.0e-3
  end

  test "Score result has expected within the level range and probs over every level" do
    {:ok, %{urgency: result}} = ask({1, 64, 0})

    assert result.expected >= 0 and result.expected <= length(@levels) - 1
    assert Enum.map(result.probs, &elem(&1, 0)) == @levels
    assert result.confidence >= 0 and result.confidence <= 1
  end

  test "results carry the Random backend and provenance derived from the tainted state" do
    {:ok, %{category: result}} = ask({1, 64, 0})

    assert result.backend == Random
    assert result.provenance == %{taint: :tainted, origin: :derived, sources: ["it-0001"]}
  end

  test "is in-schema for a hundred different harness seeds" do
    for item_index <- 0..99 do
      assert {:ok, _results} = ask({1, item_index * 64 + 3, 2})
    end
  end

  test "is in-schema for a two-option Choice and a two-level Score" do
    qs = [
      Question.choice(:client, "Which client?", OptionSet.new!(~w(client-a none))),
      Question.score(:urgency, "How urgent?", ~w(low high))
    ]

    assert {:ok, _results} = ask({5, 128, 1}, qs)
  end

  test "identical harness_seed gives identical results" do
    {:ok, first} = ask({1, 64, 0})
    {:ok, second} = ask({1, 64, 0})

    assert without_latency(first) == without_latency(second)
  end

  test "a different harness_seed gives different results" do
    {:ok, first} = ask({1, 64, 0})
    {:ok, other_order} = ask({1, 64, 1})
    {:ok, other_item} = ask({1, 65, 0})
    {:ok, other_seed} = ask({2, 64, 0})

    assert without_latency(first) != without_latency(other_order)
    assert without_latency(first) != without_latency(other_item)
    assert without_latency(first) != without_latency(other_seed)
  end

  test "info/0 reports model_id eval-random and supports all three question types" do
    info = Random.info()

    assert info.model_id == "eval-random"
    assert Enum.sort(info.types) == [:choice, :noul, :score]
  end
end
