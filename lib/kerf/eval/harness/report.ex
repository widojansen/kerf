defmodule Kerf.Eval.Harness.Report do
  @moduledoc """
  SPEC_H F09.8 / F07.3 — renders the `Kerf.Eval.Harness.Score` report map
  (plan §2.4) as JSON with keys sorted at every depth, so two reports of the
  same run are byte-identical, and as a deterministic Markdown summary whose
  only timestamp is `run.started_at`.
  """

  alias Kerf.Eval.Harness.Score

  @spec to_json(Score.report()) :: iodata()
  def to_json(_report), do: not_implemented("F09.8")

  @spec to_markdown(Score.report()) :: String.t()
  def to_markdown(_report), do: not_implemented("F09.8")

  # RED skeleton. The dynamic apply/3 keeps Elixir's cross-module type inference
  # from typing every caller's result as none(), which would turn each test that
  # uses a result into a compile warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
