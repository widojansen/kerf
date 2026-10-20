defmodule Kerf.Eval.Adapters.Random do
  @moduledoc """
  SPEC_H F09.9 — the known-bad adapter: uniform random probabilities,
  deterministic from `opts[:harness_seed]`. Must fail F09.1, F09.7 and raw
  F09.2 (addendum 03, A3.2).

  `opts[:harness_seed]` is an integer or the 3-tuple `:rand.seed_s/2` accepts
  (A3.11). Only the functional `:rand` API is used with the state threaded
  through the questions, so the caller's process `:rand` state is never read
  or changed (plan S-21).
  """

  @behaviour Kerf.Decide.Adapter

  alias Kerf.Decide.OptionSet
  alias Kerf.Decide.Question.{Choice, Noul, Score}

  @impl true
  @spec ask(Kerf.Decide.State.t(), [Kerf.Decide.Question.t()], keyword()) ::
          {:ok, %{atom() => map()}} | {:error, term()}
  def ask(_state, questions, opts) do
    case Keyword.fetch(opts, :harness_seed) do
      {:ok, seed} when is_integer(seed) ->
        answer_all(questions, :rand.seed_s(:exsss, seed))

      {:ok, {a, b, c} = seed} when is_integer(a) and is_integer(b) and is_integer(c) ->
        answer_all(questions, :rand.seed_s(:exsss, seed))

      {:ok, other} ->
        {:error, {:invalid_harness_seed, other}}

      :error ->
        {:error, :missing_harness_seed}
    end
  end

  @impl true
  @spec info() :: Kerf.Decide.Adapter.info()
  def info do
    %{
      model_id: "eval-random",
      types: [:noul, :choice, :score],
      max_state_tokens: 8192,
      languages: ["nl", "de", "en"]
    }
  end

  defp answer_all(questions, rand_state) do
    {answers, _state} =
      Enum.reduce(questions, {%{}, rand_state}, fn question, {acc, state} ->
        {answer, state} = answer(question, state)
        {Map.put(acc, question.name, answer), state}
      end)

    {:ok, answers}
  end

  defp answer(%Noul{}, state) do
    {p_yes, state} = :rand.uniform_s(state)
    {%{p_yes: p_yes}, state}
  end

  defp answer(%Choice{options: options}, state) do
    {probs, state} = random_probs(OptionSet.labels(options), state)
    {%{probs: probs}, state}
  end

  defp answer(%Score{levels: levels}, state) do
    {probs, state} = random_probs(levels, state)
    k = length(levels)

    expected =
      probs |> Enum.with_index() |> Enum.reduce(0.0, fn {{_level, p}, i}, sum -> sum + i * p end)

    p_max = probs |> Enum.map(&elem(&1, 1)) |> Enum.max()

    {%{expected: min(expected, k - 1.0), probs: probs, confidence: (p_max - 1 / k) / (1 - 1 / k)},
     state}
  end

  # Normalised uniform weights; 1.0 - u is in (0, 1], so the total is positive.
  defp random_probs(labels, state) do
    {weights, state} =
      Enum.map_reduce(labels, state, fn _label, state ->
        {u, state} = :rand.uniform_s(state)
        {1.0 - u, state}
      end)

    total = Enum.sum(weights)
    {Enum.zip(labels, Enum.map(weights, &(&1 / total))), state}
  end
end
