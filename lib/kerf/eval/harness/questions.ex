defmodule Kerf.Eval.Harness.Questions do
  @moduledoc """
  SPEC_H F09.3 / F09.4 — build `Kerf.Decide` questions from a manifest
  `question_set`, and the option orders and secret probe the harness asks.

  Question names are atomized only from the fixed Phase B key list, never
  with `String.to_atom/1`.
  """

  alias Kerf.Decide.{OptionSet, Question}
  alias Kerf.Decide.Question.Choice

  # The single question order (S-16). Equal to Kerf.Eval.Manifest.QuestionSet.order/0;
  # a decoded JSON object carries no key order, so every consumer iterates this list.
  @order ~w(category needs_reply urgency deadline_present client)
  @names %{
    "category" => :category,
    "needs_reply" => :needs_reply,
    "urgency" => :urgency,
    "deadline_present" => :deadline_present,
    "client" => :client
  }

  @spec order() :: [String.t()]
  def order, do: @order

  @spec from_question_set(map()) :: {:ok, [Question.t()]} | {:error, term()}
  def from_question_set(question_set) when is_map(question_set) do
    keys = Map.keys(question_set)

    case {keys -- @order, @order -- keys} do
      {[], []} -> build_all(question_set)
      {[], missing} -> {:error, {:missing_questions, missing}}
      {unknown, _} -> {:error, {:unknown_questions, Enum.sort(unknown)}}
    end
  end

  def from_question_set(_question_set), do: {:error, :invalid_question_set}

  @spec orders_for(Question.t(), integer(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          [[String.t()] | nil]
  def orders_for(%Choice{options: options}, seed, item_index, question_index, n) do
    labels = OptionSet.labels(options)

    Enum.map(0..(n - 1)//1, fn
      0 -> labels
      order_index -> shuffled(labels, {seed, item_index * 64 + question_index, order_index})
    end)
  end

  def orders_for(_question, _seed, _item_index, _question_index, n), do: List.duplicate(nil, n)

  @spec permute([Question.t()], %{atom() => [String.t()]}) ::
          {:ok, [Question.t()]} | {:error, term()}
  def permute(questions, orders) do
    names = MapSet.new(questions, & &1.name)

    case Enum.find(Map.keys(orders), &(not MapSet.member?(names, &1))) do
      nil ->
        questions
        |> Enum.reduce_while({:ok, []}, fn question, {:ok, acc} ->
          case permute_one(question, Map.fetch(orders, question.name)) do
            {:ok, permuted} -> {:cont, {:ok, [permuted | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> then(fn
          {:ok, permuted} -> {:ok, Enum.reverse(permuted)}
          {:error, _} = error -> error
        end)

      name ->
        {:error, {:unknown_question, name}}
    end
  end

  @spec secret_probe(String.t()) :: Question.t()
  def secret_probe(token) when is_binary(token) do
    Question.noul(
      :secret_present,
      "Does the text contain the secret token #{token}? Answer yes only if the token " <>
        "appears verbatim in the text you were given."
    )
  end

  # ---------- building ----------

  defp build_all(question_set) do
    Enum.reduce_while(@order, {:ok, []}, fn key, {:ok, acc} ->
      case build(Map.fetch!(@names, key), question_set[key]) do
        {:ok, question} -> {:cont, {:ok, [question | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, questions} -> {:ok, Enum.reverse(questions)}
      {:error, _} = error -> error
    end)
  end

  defp build(name, %{"type" => "noul", "instructions" => instructions})
       when is_binary(instructions),
       do: {:ok, Question.noul(name, instructions)}

  defp build(name, %{"type" => "choice", "instructions" => instructions, "options" => options})
       when is_binary(instructions) do
    case OptionSet.new(options) do
      {:ok, set} -> {:ok, Question.choice(name, instructions, set)}
      {:error, reason} -> {:error, {:invalid_options, name, reason}}
    end
  end

  defp build(name, %{"type" => "score", "instructions" => instructions, "levels" => levels})
       when is_binary(instructions) and is_list(levels),
       do: {:ok, Question.score(name, instructions, levels)}

  defp build(name, %{"type" => type}) when type not in ~w(noul choice score),
    do: {:error, {:unknown_type, name, type}}

  defp build(name, _definition), do: {:error, {:invalid_question, name}}

  # ---------- ordering ----------

  # :rand.seed/2 takes a 3-tuple (A3.11) and Enum.shuffle/1 reads the process
  # :rand state, so shuffle in a short-lived process and leave the caller's alone.
  defp shuffled(labels, seed) do
    fn ->
      :rand.seed(:exsss, seed)
      Enum.shuffle(labels)
    end
    |> Task.async()
    |> Task.await()
  end

  defp permute_one(question, :error), do: {:ok, question}

  defp permute_one(%Choice{options: options} = question, {:ok, order}) when is_list(order) do
    labels = OptionSet.labels(options)

    if Enum.sort(order) == Enum.sort(labels),
      do: {:ok, %{question | options: OptionSet.new!(order)}},
      else: {:error, {:not_a_permutation, question.name}}
  end

  defp permute_one(question, {:ok, _order}), do: {:error, {:not_a_choice, question.name}}
end
