defmodule Kerf.Eval.Manifest.QuestionSet do
  @moduledoc """
  SPEC_H F08.2 — the Phase B question set, defined once (F11 reuses it).

  `order/0` is the single source of question order (ruling S-16): a
  `question_set` is a plain map and does not preserve order, so every
  consumer iterates `order/0`.
  """

  @spec order() :: [String.t()]
  def order, do: not_implemented("F08.2")

  @spec phase_b([String.t()]) :: %{String.t() => Kerf.Eval.Manifest.question_def()}
  def phase_b(_clients), do: not_implemented("F08.2")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
