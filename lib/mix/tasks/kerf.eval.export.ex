defmodule Mix.Tasks.Kerf.Eval.Export do
  @shortdoc "Export Decide eval candidates from the Spark into a manifest (SPEC_H F08)"
  @moduledoc """
  SPEC_H F08.1 / F08.7 — read-only export over ssh + psql.

      mix kerf.eval.export --out PATH --overrides PATH --clients PATH \\
        [--since 180d] [--limit 600] [--target 220] [--host spark] [--db NAME] \\
        [--raw raw.jsonl] [--hashes-out PATH]

  RED skeleton.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_argv),
    do:
      apply(:erlang, :error, [
        RuntimeError.exception("not implemented (SPEC_H F08.1 export task)")
      ])
end
