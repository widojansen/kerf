defmodule Mix.Tasks.Kerf.Eval.Freeze do
  @shortdoc "Freeze a labelled Decide manifest (SPEC_H F08.4/F08.5) — owner only"
  @moduledoc """
  SPEC_H F08.4 / F08.5 — point of no return for the label set. Owner-only.

      mix kerf.eval.freeze --manifest PATH --seed N [--allow-mix-shortfall]

  RED skeleton.
  """
  use Mix.Task

  @type config :: %{manifest: Path.t(), seed: integer(), allow_mix_shortfall: boolean()}

  @spec parse_args([String.t()]) :: {:ok, config()} | {:error, String.t()}
  def parse_args(_argv),
    do:
      apply(:erlang, :error, [
        RuntimeError.exception("not implemented (SPEC_H F08.4 freeze parse_args)")
      ])

  @impl Mix.Task
  def run(_argv),
    do:
      apply(:erlang, :error, [
        RuntimeError.exception("not implemented (SPEC_H F08.4 freeze task)")
      ])
end
