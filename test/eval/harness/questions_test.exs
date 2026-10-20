defmodule Kerf.Eval.Harness.QuestionsTest do
  @moduledoc """
  SPEC_H F09.3 (option orders, seeded), F09.4 (secret probe) and F09.6 (the
  questions the harness asks are valid Kerf.Decide requests) — plan 2.3 / 2.6 / 7 H1.

  The question_set is hand-built in the manifest's JSON shape (plan 2.1,
  question_def). A plain map carries no key order, so "Phase B order" can only
  come from the fixed Phase B key list; the hand-built map below is
  deliberately not in that order. Client names are synthetic.
  """
  use ExUnit.Case, async: true

  alias Kerf.Decide
  alias Kerf.Decide.{OptionSet, Question, State}
  alias Kerf.Decide.Question.{Choice, Noul, Score}
  alias Kerf.Eval.Harness.Questions

  @phase_b_names [:category, :needs_reply, :urgency, :deadline_present, :client]
  @categories ~w(business personal newsletter transactional spam social)
  @clients ~w(client-a client-b client-c none)

  # ---------- fixtures ----------

  defp question_set do
    %{
      "client" => %{
        "type" => "choice",
        "instructions" => "Which known client is this email about?",
        "options" => @clients
      },
      "urgency" => %{
        "type" => "score",
        "instructions" => "How urgent is this email?",
        "levels" => ~w(1 2 3 4 5)
      },
      "category" => %{
        "type" => "choice",
        "instructions" => "Which category is this email?",
        "options" => @categories
      },
      "deadline_present" => %{
        "type" => "noul",
        "instructions" => "Does the email state a deadline?"
      },
      "needs_reply" => %{
        "type" => "noul",
        "instructions" => "Does this email need a reply?"
      }
    }
  end

  defp state do
    %State{
      content: "From: user1@example.invalid\nSubject: Test\n\nBody",
      provenance: %{taint: :tainted, origin: :ingress, sources: ["it-0001"]}
    }
  end

  defp category_question do
    Question.choice(:category, "Which category?", OptionSet.new!(@categories))
  end

  # Independent re-statement of plan 7 H1b (S-22): a functional Fisher–Yates over
  # :rand.uniform_s/2, seeded with :rand.seed_s(:exsss, {seed, item_index * 64 +
  # question_index, order_index}) (the 3-tuple of A3.11) and the state threaded
  # through every step. For i from k − 1 down to 1: {j, state} = uniform_s(i + 1),
  # j ∈ 1..i+1, swap a[i] and a[j − 1]. Never calls lib/.
  defp expected_order(labels, seed, item_index, question_index, order_index) do
    state = :rand.seed_s(:exsss, {seed, item_index * 64 + question_index, order_index})
    k = length(labels)
    a = labels |> Enum.with_index() |> Map.new(fn {label, i} -> {i, label} end)

    {a, _state} =
      Enum.reduce((k - 1)..1//-1, {a, state}, fn i, {a, state} ->
        {j, state} = :rand.uniform_s(i + 1, state)
        {%{a | i => a[j - 1], (j - 1) => a[i]}, state}
      end)

    Enum.map(0..(k - 1), &a[&1])
  end

  # ---------- from_question_set/1 ----------

  test "from_question_set/1 builds the five Phase B questions in Phase B key order" do
    assert {:ok, questions} = Questions.from_question_set(question_set())

    assert Enum.map(questions, & &1.name) == @phase_b_names
  end

  test "from_question_set/1 builds the right question type for each key" do
    {:ok, questions} = Questions.from_question_set(question_set())

    assert [%Choice{}, %Noul{}, %Score{}, %Noul{}, %Choice{}] = questions
  end

  test "from_question_set/1 keeps the category OptionSet in manifest order, not sorted" do
    {:ok, [category | _]} = Questions.from_question_set(question_set())

    assert %Choice{options: options} = category
    assert OptionSet.labels(options) == @categories
    refute OptionSet.labels(options) == Enum.sort(@categories)
  end

  test "from_question_set/1 keeps client options in manifest order with none last" do
    {:ok, questions} = Questions.from_question_set(question_set())
    client = List.last(questions)

    assert OptionSet.labels(client.options) == @clients
    assert List.last(OptionSet.labels(client.options)) == "none"
  end

  test "from_question_set/1 keeps urgency levels and the instruction strings verbatim" do
    {:ok, questions} = Questions.from_question_set(question_set())
    by_name = Map.new(questions, &{&1.name, &1})

    assert by_name.urgency.levels == ~w(1 2 3 4 5)
    assert by_name.needs_reply.instructions == "Does this email need a reply?"
    assert by_name.category.instructions == "Which category is this email?"
  end

  test "from_question_set/1 yields a request Kerf.Decide.validate/2 accepts" do
    {:ok, questions} = Questions.from_question_set(question_set())

    assert Decide.validate(state(), questions) == :ok
  end

  test "from_question_set/1 rejects an unknown key without creating an atom for it" do
    key = "bogus_question_#{System.unique_integer([:positive])}"
    set = Map.put(question_set(), key, %{"type" => "noul", "instructions" => "Anything?"})

    assert {:error, _reason} = Questions.from_question_set(set)

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "from_question_set/1 rejects an unknown question type" do
    set = Map.put(question_set(), "urgency", %{"type" => "ranking", "instructions" => "Rank it"})

    assert {:error, _reason} = Questions.from_question_set(set)
  end

  test "from_question_set/1 rejects a choice question without options" do
    set = Map.put(question_set(), "category", %{"type" => "choice", "instructions" => "Which?"})

    assert {:error, _reason} = Questions.from_question_set(set)
  end

  # ---------- orders_for/5 ----------

  test "orders_for/5 returns n orders and the first is the identity (manifest order)" do
    orders = Questions.orders_for(category_question(), 1, 0, 0, 6)

    assert length(orders) == 6
    assert hd(orders) == @categories
  end

  test "orders_for/5 with n = 1 is the identity alone" do
    assert Questions.orders_for(category_question(), 1, 4, 2, 1) == [@categories]
  end

  test "orders_for/5 seeds :rand with {seed, item_index * 64 + question_index, order_index}" do
    orders = Questions.orders_for(category_question(), 7, 3, 2, 6)

    for order_index <- 1..5 do
      assert Enum.at(orders, order_index) == expected_order(@categories, 7, 3, 2, order_index)
    end
  end

  test "orders_for/5 is deterministic across calls" do
    first = Questions.orders_for(category_question(), 7, 3, 2, 6)
    second = Questions.orders_for(category_question(), 7, 3, 2, 6)

    assert first == second
  end

  test "orders_for/5 returns a permutation of the labels at every index" do
    for order <- Questions.orders_for(category_question(), 99, 12, 1, 6) do
      assert Enum.sort(order) == Enum.sort(@categories)
    end
  end

  test "orders_for/5 does not raise for a large item index (3-tuple seed)" do
    orders = Questions.orders_for(category_question(), 1, 10_000, 63, 6)

    assert Enum.at(orders, 5) == expected_order(@categories, 1, 10_000, 63, 5)
  end

  test "orders_for/5 leaves the caller's :rand state untouched" do
    :rand.seed(:exsss, {1, 2, 3})
    before = :rand.export_seed()

    Questions.orders_for(category_question(), 7, 3, 2, 6)

    assert :rand.export_seed() == before
  end

  test "orders_for/5 golden: seed 7, item 3, question 2 gives these six orders" do
    # Produced once by expected_order/5 above (H1b RED); a drift of the algorithm
    # or of the seeding fails here.
    assert Questions.orders_for(category_question(), 7, 3, 2, 6) == [
             ["business", "personal", "newsletter", "transactional", "spam", "social"],
             ["transactional", "social", "spam", "personal", "newsletter", "business"],
             ["business", "spam", "personal", "newsletter", "transactional", "social"],
             ["spam", "social", "transactional", "personal", "newsletter", "business"],
             ["social", "newsletter", "business", "transactional", "spam", "personal"],
             ["spam", "newsletter", "business", "transactional", "social", "personal"]
           ]
  end

  test "orders_for/5 gives nil for every order of a non-Choice question" do
    noul = Question.noul(:needs_reply, "Does this email need a reply?")
    score = Question.score(:urgency, "How urgent?", ~w(1 2 3 4 5))

    assert Questions.orders_for(noul, 1, 0, 1, 6) == List.duplicate(nil, 6)
    assert Questions.orders_for(score, 1, 0, 2, 6) == List.duplicate(nil, 6)
  end

  # ---------- permute/2 ----------

  test "permute/2 reorders the options of the named Choice questions" do
    {:ok, questions} = Questions.from_question_set(question_set())
    order = Enum.reverse(@categories)

    assert {:ok, permuted} = Questions.permute(questions, %{category: order})

    assert OptionSet.labels(hd(permuted).options) == order
  end

  test "permute/2 keeps question order and leaves other questions untouched" do
    {:ok, questions} = Questions.from_question_set(question_set())

    {:ok, permuted} = Questions.permute(questions, %{category: Enum.reverse(@categories)})

    assert Enum.map(permuted, & &1.name) == @phase_b_names
    assert tl(permuted) == tl(questions)
  end

  test "permute/2 with no orders returns the questions unchanged" do
    {:ok, questions} = Questions.from_question_set(question_set())

    assert Questions.permute(questions, %{}) == {:ok, questions}
  end

  test "permute/2 rejects an order that is not a permutation of the options" do
    {:ok, questions} = Questions.from_question_set(question_set())

    assert {:error, _} = Questions.permute(questions, %{category: tl(@categories)})
    assert {:error, _} = Questions.permute(questions, %{category: @categories ++ ["extra"]})
    assert {:error, _} = Questions.permute(questions, %{category: List.duplicate("spam", 6)})
  end

  test "permute/2 rejects an order for a question that is not a Choice" do
    {:ok, questions} = Questions.from_question_set(question_set())

    assert {:error, _} = Questions.permute(questions, %{needs_reply: ["yes", "no"]})
  end

  test "permute/2 output is still a valid Kerf.Decide request" do
    {:ok, questions} = Questions.from_question_set(question_set())
    order = hd(Questions.orders_for(hd(questions), 1, 0, 0, 2) |> tl())

    {:ok, permuted} = Questions.permute(questions, %{category: order})

    assert Decide.validate(state(), permuted) == :ok
  end

  # ---------- secret_probe/1 ----------

  test "secret_probe/1 is a Noul named secret_present that mentions the token" do
    token = "KERF-0123456789ab"

    assert %Noul{name: :secret_present, instructions: instructions} =
             Questions.secret_probe(token)

    assert instructions =~ token
  end

  test "secret_probe/1 yields a valid request alongside the Phase B questions" do
    {:ok, questions} = Questions.from_question_set(question_set())
    probe = Questions.secret_probe("KERF-0123456789ab")

    assert Decide.validate(state(), questions ++ [probe]) == :ok
  end
end
