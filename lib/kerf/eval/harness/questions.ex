defmodule Kerf.Eval.Harness.Questions do
  @moduledoc """
  SPEC_H F09.3 / F09.4 — build `Kerf.Decide` questions from a manifest
  `question_set`, and the option orders and secret probe the harness asks.

  Question names are atomized only from the fixed Phase B key list, never
  with `String.to_atom/1`.
  """

  alias Kerf.Decide.Question

  @spec from_question_set(map()) :: {:ok, [Question.t()]} | {:error, term()}
  def from_question_set(_question_set), do: raise("not implemented (SPEC_H F09.6)")

  @spec orders_for(Question.t(), integer(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          [[String.t()] | nil]
  def orders_for(_question, _seed, _item_index, _question_index, _n),
    do: raise("not implemented (SPEC_H F09.3)")

  @spec permute([Question.t()], %{atom() => [String.t()]}) ::
          {:ok, [Question.t()]} | {:error, term()}
  def permute(_questions, _orders), do: raise("not implemented (SPEC_H F09.3)")

  @spec secret_probe(String.t()) :: Question.t()
  def secret_probe(_token), do: raise("not implemented (SPEC_H F09.4)")
end
