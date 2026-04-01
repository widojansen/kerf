defmodule ExClaw.StructuredOutput.JSONParser do
  @moduledoc """
  Extracts and parses JSON from LLM response content.

  Handles common LLM output patterns:
  - Raw JSON
  - JSON wrapped in ```json fences
  - JSON preceded by <think>...</think> tags
  - JSON with leading/trailing text
  """

  @doc """
  Parse JSON from LLM response content.

  Returns `{:ok, map() | list()}` or `{:error, reason}`.
  """
  @spec parse(binary() | nil) :: {:ok, map() | list()} | {:error, String.t()}
  def parse(nil), do: {:error, "empty content"}
  def parse(""), do: {:error, "empty content"}

  def parse(content) when is_binary(content) do
    content
    |> strip_think_tags()
    |> extract_from_fences()
    |> try_parse()
  end

  # Strip <think>...</think> blocks (vLLM/Qwen thinking output)
  defp strip_think_tags(content) do
    Regex.replace(~r/<think>[\s\S]*?<\/think>/s, content, "")
  end

  # Extract JSON from ```json ... ``` or ``` ... ``` fences
  defp extract_from_fences(content) do
    case Regex.run(~r/```(?:json)?\s*\n?([\s\S]*?)```/s, content) do
      [_, inner] -> String.trim(inner)
      nil -> String.trim(content)
    end
  end

  # Try parsing the content as JSON, with fallback extraction strategies
  defp try_parse(""), do: {:error, "empty content after extraction"}

  defp try_parse(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) or is_list(data) ->
        {:ok, data}

      _ ->
        extract_json_substring(content)
    end
  end

  # Find the first valid JSON object or array in the string
  defp extract_json_substring(content) do
    with {:error, _} <- try_extract(content, ?{, ?}),
         {:error, _} <- try_extract(content, ?[, ?]) do
      {:error, "no valid JSON found in content"}
    end
  end

  defp try_extract(content, open_char, close_char) do
    case find_balanced(content, open_char, close_char) do
      {:ok, json_str} ->
        case Jason.decode(json_str) do
          {:ok, data} when is_map(data) or is_list(data) -> {:ok, data}
          _ -> {:error, "invalid JSON"}
        end

      :error ->
        {:error, "no balanced JSON found"}
    end
  end

  # Find the first balanced JSON substring starting with open_char
  defp find_balanced(content, open_char, close_char) do
    case :binary.match(content, <<open_char>>) do
      {start, _} ->
        substring = binary_part(content, start, byte_size(content) - start)
        scan_balanced(substring, open_char, close_char)

      :nomatch ->
        :error
    end
  end

  defp scan_balanced(content, open_char, close_char) do
    content
    |> String.to_charlist()
    |> do_scan(open_char, close_char, 0, false, false, [])
  end

  defp do_scan([], _open, _close, _depth, _in_str, _escaped, _acc), do: :error

  defp do_scan([ch | rest], open, close, depth, in_str, true, acc) do
    # Previous char was backslash — this char is escaped
    do_scan(rest, open, close, depth, in_str, false, [ch | acc])
  end

  defp do_scan([?\\ | rest], open, close, depth, true = _in_str, false, acc) do
    do_scan(rest, open, close, depth, true, true, [?\\ | acc])
  end

  defp do_scan([?" | rest], open, close, depth, true = _in_str, false, acc) do
    # Closing quote
    do_scan(rest, open, close, depth, false, false, [?" | acc])
  end

  defp do_scan([ch | rest], open, close, depth, true = _in_str, false, acc) do
    # Inside string — skip
    do_scan(rest, open, close, depth, true, false, [ch | acc])
  end

  defp do_scan([?" | rest], open, close, depth, false, false, acc) do
    do_scan(rest, open, close, depth, true, false, [?" | acc])
  end

  defp do_scan([ch | rest], open, close, depth, false, false, acc) when ch == open do
    new_depth = depth + 1
    do_scan(rest, open, close, new_depth, false, false, [ch | acc])
  end

  defp do_scan([ch | rest], open, close, depth, false, false, acc) when ch == close do
    new_depth = depth - 1

    if new_depth == 0 do
      result = [ch | acc] |> Enum.reverse() |> List.to_string()
      {:ok, result}
    else
      do_scan(rest, open, close, new_depth, false, false, [ch | acc])
    end
  end

  defp do_scan([ch | rest], open, close, depth, false, false, acc) do
    do_scan(rest, open, close, depth, false, false, [ch | acc])
  end
end
