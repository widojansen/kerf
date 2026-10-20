defmodule Kerf.Eval.Manifest.Language do
  @moduledoc """
  SPEC_H F08.1 / A3.5 — stopword-ratio language heuristic used by the export
  (`language_source: "heuristic"`); the owner corrects it while labelling.
  """

  @spec guess(String.t()) :: String.t()
  def guess(_text), do: not_implemented("F08.1")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
