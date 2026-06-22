defmodule Kerf.Agents.EmailTriage.BodyPrep do
  @moduledoc """
  Pure, deterministic body preparation for email summarisation.

  Replaces the naive positional `String.slice(text, 0, 2000)` cut that fed the
  summariser raw newsletter chrome (table-of-contents, nav menus, "view in
  browser" headers, tracking links, unsubscribe footers) — pushing the
  substantive content named in the subject past the cut.

  `prepare/2` runs, in order:

    1. Cut the footer block: everything from the first `unsubscribe` line on
       (catches the unsubscribe line itself and the address/legal block after it).
    2. Reject per-line boilerplate: view-in-browser headers, edition/TOC headers
       (`INHOUD`/`CONTENTS`/…), numbered TOC items, repeated separator rules, and
       URL/tracking-dominant lines.
    3. Collapse intra-line whitespace runs and runs of blank lines.
    4. Cap the result to `opts[:budget]` bytes (default `@default_budget`),
       truncating on a valid UTF-8 boundary so multibyte graphemes are never split.

  Empty or whitespace-only input returns `""` so the caller's synthetic-body
  fallback (see `Kerf.LLM.Enrich`) still engages.

  Pure: no DB, no process, no I/O.
  """

  @default_budget 4000

  @unsubscribe_re ~r/unsubscribe/i
  @browser_re ~r/view\s+(this\s+)?(email|message|newsletter)\s+in\s+(your\s+)?browser/i
  @edition_re ~r/\b(edition|editie|issue|uitgave)\b[^\n]*\d/i
  @toc_header_re ~r/^\s*(inhoud|contents|table of contents|in this (issue|newsletter|email))\b/i
  @toc_item_re ~r/^\s*\d+\.\s+[A-Z][A-Za-z&\/ ]{0,20}$/
  @separator_re ~r/^\s*[-=_*~#·•]{3,}\s*$/
  @url_re ~r{https?://\S+}i

  @doc "Default byte budget applied when `:budget` is not supplied."
  def default_budget, do: @default_budget

  @doc """
  Prepare `raw_text` for summarisation within `opts[:budget]` bytes.

  Returns cleaned text (boilerplate stripped, whitespace collapsed) capped to the
  budget, or `""` for nil/non-binary/empty/whitespace-only input.
  """
  @spec prepare(String.t() | nil, keyword()) :: String.t()
  def prepare(raw_text, opts \\ [])

  def prepare(raw_text, opts) when is_binary(raw_text) do
    budget = Keyword.get(opts, :budget, @default_budget)

    raw_text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> drop_footer()
    |> Enum.reject(&boilerplate_line?/1)
    |> Enum.map(&collapse_spaces/1)
    |> rejoin()
    |> String.trim()
    |> take_bytes(budget)
  end

  def prepare(_raw_text, _opts), do: ""

  # ---------- footer block ----------

  # The first unsubscribe line marks the start of the footer; drop it and
  # everything after (address, legal, social links).
  defp drop_footer(lines) do
    case Enum.find_index(lines, &(&1 =~ @unsubscribe_re)) do
      nil -> lines
      idx -> Enum.take(lines, idx)
    end
  end

  # ---------- per-line boilerplate ----------

  # Blank lines are NOT boilerplate here — they are paragraph separators handled
  # (and collapsed) in rejoin/1.
  defp boilerplate_line?(line) do
    t = String.trim(line)

    cond do
      t == "" -> false
      t =~ @browser_re -> true
      t =~ @edition_re -> true
      t =~ @toc_header_re -> true
      t =~ @toc_item_re -> true
      t =~ @separator_re -> true
      url_dominant?(t) -> true
      true -> false
    end
  end

  # A line is URL-dominant when http(s) URLs make up at least half its
  # non-whitespace characters (tracking redirects, bare link lines).
  defp url_dominant?(line) do
    url_len =
      @url_re
      |> Regex.scan(line)
      |> Enum.map(fn [match | _] -> byte_size(match) end)
      |> Enum.sum()

    total = byte_size(String.replace(line, ~r/\s/, ""))

    total > 0 and url_len / total >= 0.5
  end

  # ---------- whitespace ----------

  defp collapse_spaces(line) do
    line
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
  end

  # Join kept lines, collapsing runs of blank lines to a single blank and
  # dropping leading blanks. Trailing blanks are removed by the caller's trim.
  defp rejoin(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      if line == "" and (acc == [] or hd(acc) == "") do
        acc
      else
        [line | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # ---------- byte budget ----------

  defp take_bytes(text, budget) when is_integer(budget) and budget >= 0 do
    if byte_size(text) <= budget do
      text
    else
      text
      |> binary_part(0, budget)
      |> trim_to_valid_utf8()
    end
  end

  # binary_part can split a multibyte grapheme, yielding invalid UTF-8. Drop
  # trailing bytes until the slice is valid again (at most 3 iterations).
  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
