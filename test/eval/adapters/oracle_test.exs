defmodule Kerf.Eval.Adapters.OracleTest do
  @moduledoc """
  SPEC_H F09.9 / F09.6 — the known-good adapter, always called through
  Kerf.Decide.ask/3 (plan 2.6): `{:ok, _}` means Decide accepted every answer.

  `opts[:harness_gold]` maps a question name to its gold label as the manifest
  stores it (plan 2.1): a category or client string, a boolean for a Noul, an
  integer 1..5 for urgency. For a Score the oracle's `expected` is the index of
  the gold level, so gold 4 on levels ["1".."5"] is expected 3.
  """
  use ExUnit.Case, async: true

  alias Kerf.Decide
  alias Kerf.Decide.{OptionSet, Question, State}
  alias Kerf.Eval.Adapters.Oracle

  @categories ~w(business personal newsletter transactional spam social)
  @clients ~w(client-a client-b client-c none)
  @levels ~w(1 2 3 4 5)

  defp state do
    %State{
      content: "From: user1@example.invalid\nSubject: Test\nDate: 2026-10-20\n\nBody",
      provenance: %{taint: :tainted, origin: :ingress, sources: ["it-0001"]}
    }
  end

  defp questions(categories \\ @categories) do
    [
      Question.choice(:category, "Which category?", OptionSet.new!(categories)),
      Question.noul(:needs_reply, "Does this email need a reply?"),
      Question.score(:urgency, "How urgent?", @levels),
      Question.noul(:deadline_present, "Is there a deadline?"),
      Question.choice(:client, "Which client?", OptionSet.new!(@clients))
    ]
  end

  defp gold(overrides \\ %{}) do
    Map.merge(
      %{
        category: "spam",
        needs_reply: true,
        urgency: 4,
        deadline_present: false,
        client: "client-b"
      },
      overrides
    )
  end

  defp ask(gold, qs \\ questions()) do
    Decide.ask(state(), qs, adapter: Oracle, harness_gold: gold)
  end

  test "answers every question through Decide.ask/3 with in-schema results" do
    assert {:ok, results} = ask(gold())

    assert results |> Map.keys() |> Enum.sort() ==
             [:category, :client, :deadline_present, :needs_reply, :urgency]
  end

  test "Choice picks the gold label" do
    {:ok, results} = ask(gold())

    assert results.category.label == "spam"
    assert results.client.label == "client-b"
  end

  test "Choice picks the gold label under any option order" do
    orders = [
      @categories,
      Enum.reverse(@categories),
      Enum.sort(@categories),
      ["spam" | List.delete(@categories, "spam")],
      List.delete(@categories, "spam") ++ ["spam"]
    ]

    for order <- orders do
      {:ok, %{category: result}} = ask(gold(), questions(order))

      assert result.label == "spam"
      assert Enum.map(result.probs, &elem(&1, 0)) == order
    end
  end

  test "Choice puts 0.97 on the gold label and spreads the rest evenly" do
    {:ok, %{category: result}} = ask(gold())

    {gold_probs, other_probs} = Enum.split_with(result.probs, &(elem(&1, 0) == "spam"))
    [{"spam", p_gold}] = gold_probs

    assert_in_delta p_gold, 0.97, 1.0e-9

    for {_label, p} <- other_probs, do: assert_in_delta(p, 0.03 / 5, 1.0e-9)
  end

  test "Choice confidence is Decide's (p_max - 1/K) / (1 - 1/K) for p_max 0.97" do
    {:ok, %{category: result}} = ask(gold())

    assert_in_delta result.confidence, (0.97 - 1 / 6) / (1 - 1 / 6), 1.0e-9
  end

  test "Noul p_yes is at least 0.9 iff gold is true" do
    {:ok, yes} = ask(gold(%{needs_reply: true, deadline_present: true}))
    {:ok, no} = ask(gold(%{needs_reply: false, deadline_present: false}))

    assert yes.needs_reply.p_yes >= 0.9
    assert yes.deadline_present.p_yes >= 0.9
    assert no.needs_reply.p_yes < 0.9
    assert no.deadline_present.p_yes < 0.9
  end

  test "Noul p_yes is 0.97 for gold true and 0.03 for gold false" do
    {:ok, yes} = ask(gold(%{needs_reply: true}))
    {:ok, no} = ask(gold(%{needs_reply: false}))

    assert_in_delta yes.needs_reply.p_yes, 0.97, 1.0e-9
    assert_in_delta no.needs_reply.p_yes, 0.03, 1.0e-9
  end

  test "Score expected is the gold level index for every level" do
    for level <- 1..5 do
      {:ok, %{urgency: result}} = ask(gold(%{urgency: level}))

      assert_in_delta result.expected, level - 1, 1.0e-9
    end
  end

  test "Score confidence is 0.97 and the probability mass sits on the gold level" do
    {:ok, %{urgency: result}} = ask(gold(%{urgency: 4}))

    assert_in_delta result.confidence, 0.97, 1.0e-9
    assert Enum.map(result.probs, &elem(&1, 0)) == @levels
    assert {"4", p_gold} = Enum.max_by(result.probs, &elem(&1, 1))
    assert_in_delta p_gold, 0.97, 1.0e-9
  end

  test "results carry the Oracle backend and provenance derived from the tainted state" do
    {:ok, %{category: result}} = ask(gold())

    assert result.backend == Oracle
    assert result.provenance == %{taint: :tainted, origin: :derived, sources: ["it-0001"]}
  end

  test "the same gold gives the same answers every time" do
    {:ok, first} = ask(gold())
    {:ok, second} = ask(gold())

    strip = fn results ->
      Map.new(results, fn {name, result} -> {name, Map.delete(result, :latency_ms)} end)
    end

    assert strip.(first) == strip.(second)
  end

  test "info/0 reports model_id eval-oracle and supports all three question types" do
    info = Oracle.info()

    assert info.model_id == "eval-oracle"
    assert Enum.sort(info.types) == [:choice, :noul, :score]
  end
end
