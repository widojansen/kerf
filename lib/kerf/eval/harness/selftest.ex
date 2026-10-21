defmodule Kerf.Eval.Harness.Selftest do
  @moduledoc """
  SPEC_H F09.9 — the harness self-test: a random run and two oracle runs over
  one manifest, scored and checked against the S-2 expectations (plan §7 H4).

  RED skeleton: `run/2` is not implemented yet.
  """

  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, [term()]}
  def run(_out_dir, _opts), do: not_implemented("Kerf.Eval.Harness.Selftest.run/2")

  # Raised through apply/3 so the type checker does not type callers' results as none().
  defp not_implemented(name),
    do: apply(:erlang, :error, [RuntimeError.exception("#{name} not implemented (RED)")])
end
