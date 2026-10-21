defmodule Kerf.Eval.Harness do
  @moduledoc """
  SPEC_H F09.3 / F09.4 / F09.6 / F09.8 / F08.4 — run a frozen manifest through
  `Kerf.Decide.ask/3` and produce the run JSONL lines (plan §2.3, §2.6, §7 H3).

  RED skeleton: `run/2` is not implemented yet.
  """

  @type run_result :: %{header: map(), lines: [map()], end: map()}

  @spec run(Kerf.Eval.Manifest.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(_manifest, _opts), do: not_implemented("Kerf.Eval.Harness.run/2")

  # Raised through apply/3 so the type checker does not type callers' results as none().
  defp not_implemented(name),
    do: apply(:erlang, :error, [RuntimeError.exception("#{name} not implemented (RED)")])
end
