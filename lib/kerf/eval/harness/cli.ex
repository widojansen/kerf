defmodule Kerf.Eval.Harness.CLI do
  @moduledoc """
  SPEC_H F09.8 / F09.9 — argv parsing and dispatch for `mix kerf.eval.decide`
  (plan §2.7, §3, §7 H4).

  RED skeleton: `parse_args/1`, `help/1` and `run/1` are not implemented yet.
  """

  @type command :: :run | :score | :normalize | :selftest

  @spec parse_args(term()) ::
          {:ok, %{required(:command) => command(), optional(atom()) => term()}}
          | {:error, String.t()}
  def parse_args(_argv), do: not_implemented("Kerf.Eval.Harness.CLI.parse_args/1")

  @spec help(command()) :: String.t()
  def help(_command), do: not_implemented("Kerf.Eval.Harness.CLI.help/1")

  @spec run(term()) :: {:ok, map()} | {:error, term()}
  def run(_argv), do: not_implemented("Kerf.Eval.Harness.CLI.run/1")

  # Raised through apply/3 so the type checker does not type callers' results as none().
  defp not_implemented(name),
    do: apply(:erlang, :error, [RuntimeError.exception("#{name} not implemented (RED)")])
end
