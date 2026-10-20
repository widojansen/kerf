defmodule Kerf.Eval.Harness.Run do
  @moduledoc """
  SPEC_H F09.8 / F09.6 — the harness run JSONL (plan §2.3).

  Line 1 is the `run_manifest` header, then one `answer` line per
  (item, question, order-permutation), and a final `run_end` line. Lines are
  plain string-keyed maps; `encode/1` writes them with the keys in the §2.3
  order so two runs are byte-comparable once `normalize/1` has dropped
  `latency_ms`, `started_at`, `finished_at` and `run_id`.
  """

  alias Jason.OrderedObject

  @type line :: %{String.t() => term()}

  @schema_version 1

  @header_order ~w(type schema_version run_id set_id manifest_path manifest_sha256
                   manifest_frozen_at adapter adapter_opts info seed permutations
                   isolation_items limit latency_skipped host kerf_git_sha started_at)
  @answer_order ~w(type item_id doc_id language tier split pair_id question qtype probe
                   packed order_index order gold result latency_ms error)
  @end_order ~w(type finished_at answers errors)
  @result_order ~w(label expected p_yes probs confidence)

  @line_orders %{
    "run_manifest" => @header_order,
    "answer" => @answer_order,
    "run_end" => @end_order
  }

  # Only these keys of a Kerf.Decide result are part of the run format; backend,
  # latency_ms and provenance are dropped.
  @result_keys %{
    "noul" => ~w(p_yes),
    "choice" => ~w(label probs confidence),
    "score" => ~w(expected probs confidence)
  }

  @dropped_by_normalize ~w(latency_ms started_at finished_at run_id)

  @spec header(map()) :: line()
  def header(fields) do
    fields
    |> jsonable()
    |> Map.merge(%{"type" => "run_manifest", "schema_version" => @schema_version})
  end

  @spec answer_line(map()) :: line()
  def answer_line(fields) do
    line = fields |> jsonable() |> Map.put("type", "answer")

    case line do
      %{"result" => result} -> %{line | "result" => filter_result(line["qtype"], result)}
      _ -> line
    end
  end

  @spec end_line(map()) :: line()
  def end_line(fields), do: fields |> jsonable() |> Map.put("type", "run_end")

  @spec encode(line()) :: String.t()
  def encode(line) do
    line |> jsonable() |> ordered_line() |> Jason.encode!()
  end

  @spec write(Path.t(), line(), [line()]) :: :ok | {:error, term()}
  def write(path, header, lines) do
    data = Enum.map_join([header | lines], "", &(encode(&1) <> "\n"))
    File.write(path, data)
  end

  @spec read(Path.t()) :: {:ok, {line(), [line()], line()}} | {:error, term()}
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, lines} <- decode_lines(text),
         {:ok, header, rest} <- take_header(lines),
         {:ok, answers, run_end} <- take_end(rest) do
      {:ok, {header, answers, run_end}}
    end
  end

  @spec normalize(binary()) :: {:ok, binary()} | {:error, term()}
  def normalize(jsonl) when is_binary(jsonl) do
    jsonl
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case Jason.decode(text, objects: :ordered_objects) do
        {:ok, %OrderedObject{values: values}} ->
          kept = Enum.reject(values, fn {key, _} -> key in @dropped_by_normalize end)
          {:cont, {:ok, [Jason.encode!(%OrderedObject{values: kept}) | acc]}}

        {:ok, _not_an_object} ->
          {:halt, {:error, :not_a_json_object}}

        {:error, error} ->
          {:halt, {:error, {:invalid_json, error}}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, encoded |> Enum.reverse() |> Enum.map_join("", &(&1 <> "\n"))}
      {:error, _} = error -> error
    end
  end

  # ---------- reading ----------

  defp decode_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case Jason.decode(text) do
        {:ok, %{} = line} -> {:cont, {:ok, [line | acc]}}
        {:ok, _not_an_object} -> {:halt, {:error, :not_a_json_object}}
        {:error, error} -> {:halt, {:error, {:invalid_json, error}}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :empty}
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      {:error, _} = error -> error
    end
  end

  defp take_header([%{"type" => "run_manifest"} = header | rest]), do: {:ok, header, rest}
  defp take_header(_lines), do: {:error, :no_header}

  defp take_end(rest) do
    case List.last(rest) do
      %{"type" => "run_end"} = run_end ->
        answers = Enum.drop(rest, -1)

        case Enum.find(answers, &(&1["type"] != "answer")) do
          nil -> {:ok, answers, run_end}
          other -> {:error, {:unexpected_line_type, other["type"]}}
        end

      _ ->
        {:error, :no_run_end}
    end
  end

  # ---------- line building ----------

  defp filter_result(_qtype, nil), do: nil

  defp filter_result(qtype, result) when is_map(result) do
    case Map.fetch(@result_keys, qtype) do
      {:ok, keys} -> Map.take(result, keys)
      :error -> result
    end
  end

  # Deep string keys; {label, p} tuples become [label, p]; atoms other than
  # nil/true/false become strings. Idempotent.
  defp jsonable(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_key(key), jsonable(value)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(value) when is_nil(value) or is_boolean(value), do: value
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value), do: value

  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key) when is_binary(key), do: key

  # ---------- encoding ----------

  defp ordered_line(line) do
    preferred = Map.get(@line_orders, line["type"], [])

    pairs =
      for key <- sort_keys(Map.keys(line), preferred) do
        {key, ordered_value(key, line[key])}
      end

    OrderedObject.new(pairs)
  end

  defp ordered_value("result", %{} = result), do: ordered(result, @result_order)
  defp ordered_value(_key, value), do: ordered(value, [])

  defp ordered(%{} = map, preferred) when not is_struct(map) do
    pairs = for key <- sort_keys(Map.keys(map), preferred), do: {key, ordered(map[key], [])}
    OrderedObject.new(pairs)
  end

  defp ordered(list, _preferred) when is_list(list), do: Enum.map(list, &ordered(&1, []))
  defp ordered(value, _preferred), do: value

  # Known keys first in their fixed order, then any others alphabetically.
  defp sort_keys(keys, preferred) do
    known = Enum.filter(preferred, &(&1 in keys))
    known ++ Enum.sort(keys -- known)
  end
end
