defmodule Mix.Tasks.Kerf.Eval.Decide do
  @shortdoc "Run, score, normalize and self-test the Decide eval harness (SPEC_H F09)"
  @moduledoc """
  SPEC_H F09 — the Decide eval harness CLI (plan §2.7).

      mix kerf.eval.decide run       --manifest M --out run.jsonl --adapter http|random|oracle|Elixir.Mod \\
                                     --seed N [--base-url URL] [--allow-remote] [--timeout MS] \\
                                     [--permutations 6] [--isolation-items 30] [--limit N] [--skip-latency]
      mix kerf.eval.decide score     --manifest M --run run.jsonl --report report.json --summary report.md \\
                                     [--baseline-accuracy F] [--host-class decoder|encoder] \\
                                     [--temperature-out temperatures.json]
      mix kerf.eval.decide normalize --run run.jsonl --out run.norm.jsonl
      mix kerf.eval.decide selftest  --out-dir DIR [--manifest M|synthetic] [--seed N]

  `--limit N` runs the first N items in manifest order; isolation items are
  chosen from the eval items in that scope. Output paths inside the repo root
  are refused. The work happens in `Kerf.Eval.Harness.CLI.run/1`; this task
  only prints.
  """
  use Mix.Task

  alias Kerf.Eval.Harness.CLI

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    # The HTTP adapter's Req needs its Finch pool; the Kerf app itself stays stopped.
    {:ok, _apps} = Application.ensure_all_started(:req)

    case CLI.run(argv) do
      {:ok, result} -> report(result)
      {:error, message} when is_binary(message) -> Mix.raise(message)
      {:error, reason} -> Mix.raise("kerf.eval.decide failed: #{inspect(reason)}")
    end
  end

  defp report(%{command: :run} = result),
    do: info("#{result.answers} answers, #{result.errors} errors -> #{result.out}")

  defp report(%{command: :score} = result),
    do: info("report #{result.report} sha256 #{result.report_sha256}")

  defp report(%{command: :normalize} = result), do: info("normalized -> #{result.out}")

  defp report(%{runs: runs} = summary) do
    for {key, run} <- Enum.sort(runs), do: info("#{key}: #{inspect(Enum.sort(run.gates))}")
    info("random scaled F09.2 (reported, not asserted): #{summary.random_scaled_f09_2}")
    info("self-test passed; oracle report sha256 #{runs.oracle_1.report_sha256}")
  end

  defp info(message), do: Mix.shell().info("[kerf.eval.decide] " <> message)
end
