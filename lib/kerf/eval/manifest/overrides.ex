defmodule Kerf.Eval.Manifest.Overrides do
  @moduledoc """
  SPEC_H F08.7 / A3.8 — loads ~/eval/golden-overrides.jsonl, whose lines are
  `{doc_id, label_true, note}` per SPEC_D §7, into `%{doc_id => category}`.
  A `label_true` outside the SPEC_C 6-value enum (A1.9) is an error.
  """

  @spec load(Path.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def load(_path), do: not_implemented("F08.7")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
