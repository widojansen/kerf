defmodule Mix.Tasks.Kerf.Eval.Freeze do
  @shortdoc "Freeze a labelled Decide manifest (SPEC_H F08.4/F08.5) — owner only"
  @moduledoc """
  SPEC_H F08.4 / F08.5 — point of no return for the label set. Owner-only.

      mix kerf.eval.freeze --manifest PATH --seed N [--allow-mix-shortfall]

  Loads the manifest, runs `Kerf.Eval.Manifest.freeze/4` (thresholds, split)
  and rewrites the file atomically. A manifest that fails the thresholds is
  left untouched.
  """
  use Mix.Task

  alias Kerf.Eval.Manifest

  @type config :: %{manifest: Path.t(), seed: integer(), allow_mix_shortfall: boolean()}

  @spec parse_args([String.t()]) :: {:ok, config()} | {:error, String.t()}
  def parse_args(argv) when is_list(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [manifest: :string, seed: :integer, allow_mix_shortfall: :boolean]
      )

    cond do
      invalid != [] ->
        {:error, "invalid option(s): " <> Enum.map_join(invalid, ", ", &elem(&1, 0))}

      rest != [] ->
        {:error, "unexpected argument(s); only --flags are accepted"}

      not Keyword.has_key?(opts, :manifest) ->
        {:error, "missing required --manifest"}

      not Keyword.has_key?(opts, :seed) ->
        {:error, "missing required --seed"}

      true ->
        {:ok,
         %{
           manifest: opts[:manifest],
           seed: opts[:seed],
           allow_mix_shortfall: Keyword.get(opts, :allow_mix_shortfall, false)
         }}
    end
  end

  def parse_args(_other), do: {:error, "argv must be a list of strings"}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    case parse_args(argv) do
      {:ok, config} -> freeze(config)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp freeze(config) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    with {:ok, manifest} <- Manifest.load(config.manifest),
         {:ok, frozen} <-
           Manifest.freeze(manifest, config.seed, now,
             allow_mix_shortfall: config.allow_mix_shortfall
           ),
         :ok <- Manifest.save(frozen, config.manifest) do
      Mix.shell().info(
        "[kerf.eval.freeze] frozen #{frozen.counts.total} items " <>
          "(#{frozen.counts.held_out} calibration) -> #{config.manifest}"
      )
    else
      {:error, violations} -> Mix.raise("freeze refused: " <> inspect(violations))
    end
  end
end
