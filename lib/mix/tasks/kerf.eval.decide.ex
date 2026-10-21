defmodule Mix.Tasks.Kerf.Eval.Decide do
  @shortdoc "Run, score, normalize and self-test the Decide eval harness (SPEC_H F09)"
  @moduledoc """
  SPEC_H F09 — `mix kerf.eval.decide run|score|normalize|selftest` (plan §2.7).

  RED skeleton: `run/1` is not implemented yet.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_argv), do: not_implemented("Mix.Tasks.Kerf.Eval.Decide.run/1")

  # Raised through apply/3 so the type checker does not type callers' results as none().
  defp not_implemented(name),
    do: apply(:erlang, :error, [RuntimeError.exception("#{name} not implemented (RED)")])
end
