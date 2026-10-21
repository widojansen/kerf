defmodule Mix.Tasks.Kerf.Eval.Export do
  @shortdoc "Export Decide eval candidates from the Spark into a manifest (SPEC_H F08)"
  @moduledoc """
  SPEC_H F08.1 / F08.7 — read-only export over ssh + psql into an unfrozen
  `manifest.json`.

      mix kerf.eval.export --out PATH --overrides PATH --clients PATH \\
        [--since 180d] [--limit 600] [--target 220] [--host spark] [--db NAME] \\
        [--raw raw.jsonl] [--hashes-out PATH]

  `--out`, `--raw` and `--hashes-out` are refused inside the repo root: the
  files hold mail. An existing `--out` is never overwritten, because it may
  hold labels. `--hashes-out` receives the SHA-256 of every exported sender
  address, for the PII guard (`KERF_EVAL_HASHES`).
  The work happens in `Kerf.Eval.Export.run/2`; this task only prints.
  """
  use Mix.Task

  alias Kerf.Eval.Export

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    case Export.run(argv, []) do
      {:ok, result} -> report(result)
      {:error, message} when is_binary(message) -> Mix.raise(message)
      {:error, reason} -> Mix.raise("export failed: #{inspect(reason)}")
    end
  end

  defp report(result) do
    Mix.shell().info(
      "[kerf.eval.export] #{result.rows} rows fetched, #{result.selected} selected, " <>
        "#{result.overrides} overrides -> #{result.manifest_path}"
    )
  end
end
