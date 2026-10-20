defmodule Kerf.Eval.Adapters.Oracle do
  @moduledoc """
  SPEC_H F09.9 — the known-good adapter: answers `opts[:harness_gold]`
  (question name => manifest gold label) with 0.97 on the gold answer.

  Gold values are as the manifest stores them (plan §2.1): a label string for a
  Choice, a boolean for a Noul, an integer or level label for a Score. A
  question with no gold entry is an error: the oracle never guesses, so the
  harness must supply a gold for every question it asks (including probes).
  """

  @behaviour Kerf.Decide.Adapter

  alias Kerf.Decide.OptionSet
  alias Kerf.Decide.Question.{Choice, Noul, Score}

  @p_gold 0.97

  @impl true
  @spec ask(Kerf.Decide.State.t(), [Kerf.Decide.Question.t()], keyword()) ::
          {:ok, %{atom() => map()}} | {:error, term()}
  def ask(_state, questions, opts) do
    gold = Keyword.get(opts, :harness_gold, %{})

    Enum.reduce_while(questions, {:ok, %{}}, fn question, {:ok, acc} ->
      with {:ok, value} <- fetch_gold(gold, question.name),
           {:ok, answer} <- answer(question, value) do
        {:cont, {:ok, Map.put(acc, question.name, answer)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  @spec info() :: Kerf.Decide.Adapter.info()
  def info do
    %{
      model_id: "eval-oracle",
      types: [:noul, :choice, :score],
      max_state_tokens: 8192,
      languages: ["nl", "de", "en"]
    }
  end

  defp fetch_gold(gold, name) do
    case Map.fetch(gold, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:no_gold, name}}
    end
  end

  defp answer(%Noul{}, gold) when is_boolean(gold),
    do: {:ok, %{p_yes: if(gold, do: @p_gold, else: 1 - @p_gold)}}

  defp answer(%Choice{name: name, options: options}, gold) do
    labels = OptionSet.labels(options)

    if gold in labels,
      do: {:ok, %{probs: spread(labels, gold)}},
      else: {:error, {:gold_not_in_options, name}}
  end

  defp answer(%Score{name: name, levels: levels}, gold) do
    level = if is_integer(gold), do: Integer.to_string(gold), else: gold

    case Enum.find_index(levels, &(&1 == level)) do
      nil -> {:error, {:gold_not_in_levels, name}}
      index -> {:ok, %{expected: index * 1.0, probs: spread(levels, level), confidence: @p_gold}}
    end
  end

  defp answer(%{name: name}, _gold), do: {:error, {:invalid_gold, name}}

  defp spread(labels, gold) do
    rest = (1 - @p_gold) / (length(labels) - 1)
    Enum.map(labels, fn label -> {label, if(label == gold, do: @p_gold, else: rest)} end)
  end
end
