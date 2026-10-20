defmodule Kerf.Eval.Manifest.Overrides do
  @moduledoc """
  SPEC_H F08.7 / A3.8 — loads ~/eval/golden-overrides.jsonl, whose lines are
  `{doc_id, label_true, note}` per SPEC_D §7, into `%{doc_id => category}`.
  A `label_true` outside the SPEC_C 6-value enum (A1.9) is an error.

  Rulings are appended to the file (SPEC_D §7), so a later line for the same
  `doc_id` supersedes an earlier one. Blank lines are skipped.
  """

  alias Kerf.Decide.OptionSet

  @spec load(Path.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def load(path) do
    with {:ok, contents} <- read(path) do
      categories = OptionSet.labels(OptionSet.triage_categories())

      contents
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
      |> Enum.reduce_while({:ok, %{}}, fn {line, line_no}, {:ok, acc} ->
        case parse_line(line, categories) do
          {:ok, doc_id, category} -> {:cont, {:ok, Map.put(acc, doc_id, category)}}
          {:error, reason} -> {:halt, {:error, {:line, line_no, reason}}}
        end
      end)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file_unreadable, reason}}
    end
  end

  defp parse_line(line, categories) do
    case Jason.decode(line) do
      {:ok, %{"doc_id" => doc_id, "label_true" => label}} when is_binary(doc_id) ->
        if label in categories,
          do: {:ok, doc_id, label},
          else: {:error, {:label_not_in_options, label}}

      {:ok, _other} ->
        {:error, :missing_doc_id_or_label_true}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}
    end
  end
end
