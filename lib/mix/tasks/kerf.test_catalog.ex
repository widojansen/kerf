defmodule Mix.Tasks.Kerf.TestCatalog do
  @moduledoc "Generate a catalog of all Kerf tests"
  @shortdoc "Generate test catalog"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [output: :string, filter: :string, summary: :boolean]
      )

    generate("test", opts)
  end

  @doc """
  Generate a test catalog from the given test directory.
  """
  def generate(test_dir, opts \\ []) do
    files = collect_files(test_dir)

    entries =
      files
      |> Enum.map(fn file ->
        content = File.read!(file)
        parsed = parse_file(content)
        relative = Path.relative_to_cwd(file)
        %{parsed: parsed, file: relative}
      end)
      |> Enum.sort_by(& &1.parsed.module)

    entries = filter(entries, opts[:filter])

    md = render_markdown(entries, summary: opts[:summary] || false)

    case opts[:output] do
      nil -> Mix.shell().info(md)
      path -> File.write!(path, md)
    end
  end

  @doc """
  Collect all *_test.exs files recursively from the given directory.
  """
  def collect_files(dir) do
    Path.wildcard(Path.join(dir, "**/*_test.exs"))
  end

  @doc """
  Parse a test file's content and extract module name, describes, tests, and tags.
  """
  def parse_file(content) do
    lines = String.split(content, "\n")

    module = extract_module(lines)
    module_tags = extract_module_tags(lines)
    {describes, top_level_tests} = extract_structure(lines)

    %{
      module: module,
      module_tags: module_tags,
      describes: describes,
      top_level_tests: top_level_tests
    }
  end

  @doc """
  Count total tests in a parsed result.
  """
  def test_count(parsed) do
    describe_tests = Enum.sum(Enum.map(parsed.describes, &length(&1.tests)))
    describe_tests + length(parsed.top_level_tests)
  end

  @doc """
  Filter entries by a pattern matching module name or file path (case-insensitive).
  """
  def filter(entries, nil), do: entries

  def filter(entries, pattern) do
    pattern_down = String.downcase(pattern)

    Enum.filter(entries, fn entry ->
      String.contains?(String.downcase(entry.parsed.module), pattern_down) or
        String.contains?(String.downcase(entry.file), pattern_down)
    end)
  end

  @doc """
  Render entries as a markdown catalog.
  """
  def render_markdown(entries, opts \\ []) do
    summary_only = Keyword.get(opts, :summary, false)
    total_tests = Enum.sum(Enum.map(entries, &test_count(&1.parsed)))
    file_count = length(entries)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    header = """
    # Kerf Test Catalog

    Generated: #{now}
    Total: #{total_tests} tests across #{file_count} #{if file_count == 1, do: "file", else: "files"}

    ## Summary

    | Module | File | Tests |
    |--------|------|-------|
    """

    summary_rows =
      entries
      |> Enum.map(fn entry ->
        display = display_name(entry.parsed.module)
        count = test_count(entry.parsed)
        "| #{display} | #{entry.file} | #{count} |"
      end)
      |> Enum.join("\n")

    if summary_only do
      header <> summary_rows <> "\n"
    else
      detail =
        entries
        |> Enum.map(&render_detail/1)
        |> Enum.join("\n")

      header <> summary_rows <> "\n\n## Detail\n\n" <> detail
    end
  end

  # --- Private ---

  defp extract_module(lines) do
    Enum.find_value(lines, "Unknown", fn line ->
      case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, line) do
        [_, name] -> name
        _ -> nil
      end
    end)
  end

  defp extract_module_tags(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/@moduletag\s+:(\w+)/, line) do
        [_, tag] -> [String.to_atom(tag)]
        _ -> []
      end
    end)
  end

  defp extract_structure(lines) do
    {describes, top_level_tests, _} =
      lines
      |> Enum.reduce({[], [], %{current_describe: nil, pending_tags: []}}, fn line, {descs, top_tests, state} ->
        cond do
          # Describe block opening
          match = Regex.run(~r/^\s*describe\s+"([^"]+)"/, line) ->
            [_, name] = match
            new_desc = %{name: name, tests: []}
            {descs, top_tests, %{state | current_describe: new_desc, pending_tags: []}}

          # Test line
          match = Regex.run(~r/^\s*test\s+"([^"]+)"/, line) ->
            [_, name] = match
            test_entry = %{name: name, tags: state.pending_tags}

            if state.current_describe do
              updated = %{state.current_describe | tests: state.current_describe.tests ++ [test_entry]}
              {descs, top_tests, %{state | current_describe: updated, pending_tags: []}}
            else
              {descs, top_tests ++ [test_entry], %{state | pending_tags: []}}
            end

          # Tag annotation
          match = Regex.run(~r/^\s*@tag\s+:(\w+)/, line) ->
            [_, tag] = match
            {descs, top_tests, %{state | pending_tags: state.pending_tags ++ [String.to_atom(tag)]}}

          # End of describe block — heuristic: track via `end` at proper indentation
          # We use a simpler approach: when we see a new describe or reach a test outside,
          # we flush the current describe. Let's use a different approach.
          # Actually, let's detect `end` blocks to close describes.
          Regex.match?(~r/^\s{2}end\s*$/, line) and state.current_describe != nil ->
            {descs ++ [state.current_describe], top_tests, %{state | current_describe: nil, pending_tags: []}}

          true ->
            {descs, top_tests, state}
        end
      end)

    # Flush any remaining open describe
    describes =
      if Map.get(%{current_describe: nil}, :current_describe) do
        describes
      else
        describes
      end

    {describes, top_level_tests}
  end

  defp display_name(module_name) do
    module_name
    |> String.replace_prefix("Kerf.", "")
    |> String.replace_suffix("Test", "")
  end

  defp render_detail(entry) do
    display = display_name(entry.parsed.module)
    count = test_count(entry.parsed)

    header = "### #{display} (#{count} tests)\n`#{entry.file}`\n\n"

    describe_sections =
      entry.parsed.describes
      |> Enum.map(fn desc ->
        tests_md = Enum.map_join(desc.tests, "\n", &"- ✓ #{&1.name}")
        "**#{desc.name}**\n#{tests_md}"
      end)
      |> Enum.join("\n\n")

    top_level =
      if entry.parsed.top_level_tests != [] do
        Enum.map_join(entry.parsed.top_level_tests, "\n", &"- ✓ #{&1.name}")
      else
        ""
      end

    parts = [describe_sections, top_level] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    header <> parts <> "\n\n"
  end
end
