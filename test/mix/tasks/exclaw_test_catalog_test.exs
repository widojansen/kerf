defmodule Mix.Tasks.Exclaw.TestCatalogTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Exclaw.TestCatalog

  @sample_test_file """
  defmodule ExClaw.Security.FileGuardTest do
    use ExUnit.Case, async: true

    @moduletag :security

    describe "check/2 with file_read" do
      test "allows workspace paths" do
        assert :ok == FileGuard.check("file_read", %{"path" => "/workspace/foo.txt"})
      end

      test "blocks path traversal with .." do
        assert {:denied, _} = FileGuard.check("file_read", %{"path" => "../etc/passwd"})
      end

      @tag :slow
      test "blocks URL-encoded traversal" do
        assert {:denied, _} = FileGuard.check("file_read", %{"path" => "%2F..%2Fetc"})
      end
    end

    describe "check/2 with file_write" do
      test "allows workspace write" do
        assert :ok == FileGuard.check("file_write", %{"path" => "/workspace/out.txt"})
      end
    end

    test "passes through non-file tools" do
      assert :ok == FileGuard.check("shell_exec", %{"command" => "ls"})
    end
  end
  """

  @sample_test_file_no_describe """
  defmodule ExClaw.Simple.ModuleTest do
    use ExUnit.Case, async: true

    test "first thing" do
      assert true
    end

    test "second thing" do
      assert true
    end
  end
  """

  @sample_nested_describe """
  defmodule ExClaw.Nested.ExampleTest do
    use ExUnit.Case, async: true

    describe "outer" do
      describe "inner" do
        test "deeply nested test" do
          assert true
        end
      end

      test "outer test" do
        assert true
      end
    end

    test "top-level test" do
      assert true
    end
  end
  """

  describe "parse_file/1" do
    test "extracts module name" do
      result = TestCatalog.parse_file(@sample_test_file)
      assert result.module == "ExClaw.Security.FileGuardTest"
    end

    test "extracts describe blocks" do
      result = TestCatalog.parse_file(@sample_test_file)
      describes = Enum.map(result.describes, & &1.name)
      assert "check/2 with file_read" in describes
      assert "check/2 with file_write" in describes
    end

    test "extracts test names within describe blocks" do
      result = TestCatalog.parse_file(@sample_test_file)
      read_describe = Enum.find(result.describes, &(&1.name == "check/2 with file_read"))
      test_names = Enum.map(read_describe.tests, & &1.name)
      assert "allows workspace paths" in test_names
      assert "blocks path traversal with .." in test_names
      assert "blocks URL-encoded traversal" in test_names
    end

    test "extracts tests outside describe blocks" do
      result = TestCatalog.parse_file(@sample_test_file)
      top_level_names = Enum.map(result.top_level_tests, & &1.name)
      assert "passes through non-file tools" in top_level_names
    end

    test "counts total tests correctly" do
      result = TestCatalog.parse_file(@sample_test_file)
      assert TestCatalog.test_count(result) == 5
    end

    test "extracts @tag annotations" do
      result = TestCatalog.parse_file(@sample_test_file)
      read_describe = Enum.find(result.describes, &(&1.name == "check/2 with file_read"))
      slow_test = Enum.find(read_describe.tests, &(&1.name == "blocks URL-encoded traversal"))
      assert :slow in slow_test.tags
    end

    test "extracts @moduletag" do
      result = TestCatalog.parse_file(@sample_test_file)
      assert :security in result.module_tags
    end

    test "handles tests outside any describe block" do
      result = TestCatalog.parse_file(@sample_test_file_no_describe)
      assert result.module == "ExClaw.Simple.ModuleTest"
      assert result.describes == []
      assert length(result.top_level_tests) == 2
      names = Enum.map(result.top_level_tests, & &1.name)
      assert "first thing" in names
      assert "second thing" in names
    end

    test "handles nested describe blocks" do
      result = TestCatalog.parse_file(@sample_nested_describe)
      assert TestCatalog.test_count(result) == 3
    end
  end

  describe "collect_files/1" do
    @tag :tmp_dir
    test "finds test files and skips non-test files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file_guard_test.exs"), @sample_test_file)
      File.write!(Path.join(tmp_dir, "test_helper.exs"), "ExUnit.start()")
      File.write!(Path.join(tmp_dir, "conn_case.ex"), "defmodule ConnCase do end")
      File.mkdir_p!(Path.join(tmp_dir, "sub"))
      File.write!(Path.join(tmp_dir, "sub/nested_test.exs"), @sample_test_file_no_describe)

      files = TestCatalog.collect_files(tmp_dir)
      basenames = Enum.map(files, &Path.basename/1)

      assert "file_guard_test.exs" in basenames
      assert "nested_test.exs" in basenames
      refute "test_helper.exs" in basenames
      refute "conn_case.ex" in basenames
    end
  end

  describe "render_markdown/2" do
    test "renders full detail by default" do
      parsed = TestCatalog.parse_file(@sample_test_file)
      entries = [%{parsed: parsed, file: "test/security/file_guard_test.exs"}]
      md = TestCatalog.render_markdown(entries, summary: false)

      assert md =~ "# ExClaw Test Catalog"
      assert md =~ "Total: 5 tests across 1 file"
      assert md =~ "Security.FileGuard"
      assert md =~ "allows workspace paths"
      assert md =~ "blocks path traversal with .."
      assert md =~ "passes through non-file tools"
    end

    test "renders summary only with --summary" do
      parsed = TestCatalog.parse_file(@sample_test_file)
      entries = [%{parsed: parsed, file: "test/security/file_guard_test.exs"}]
      md = TestCatalog.render_markdown(entries, summary: true)

      assert md =~ "# ExClaw Test Catalog"
      assert md =~ "| Security.FileGuard |"
      refute md =~ "allows workspace paths"
    end

    test "module name strips ExClaw. prefix and Test suffix" do
      parsed = TestCatalog.parse_file(@sample_test_file)
      entries = [%{parsed: parsed, file: "test/security/file_guard_test.exs"}]
      md = TestCatalog.render_markdown(entries, summary: false)

      assert md =~ "### Security.FileGuard"
      refute md =~ "### ExClaw.Security.FileGuardTest"
    end
  end

  describe "filter/2" do
    test "filters entries by module name pattern" do
      parsed1 = TestCatalog.parse_file(@sample_test_file)
      parsed2 = TestCatalog.parse_file(@sample_test_file_no_describe)

      entries = [
        %{parsed: parsed1, file: "test/security/file_guard_test.exs"},
        %{parsed: parsed2, file: "test/simple/module_test.exs"}
      ]

      filtered = TestCatalog.filter(entries, "security")
      assert length(filtered) == 1
      assert hd(filtered).parsed.module == "ExClaw.Security.FileGuardTest"
    end

    test "filters by file path pattern" do
      parsed1 = TestCatalog.parse_file(@sample_test_file)
      parsed2 = TestCatalog.parse_file(@sample_test_file_no_describe)

      entries = [
        %{parsed: parsed1, file: "test/security/file_guard_test.exs"},
        %{parsed: parsed2, file: "test/simple/module_test.exs"}
      ]

      filtered = TestCatalog.filter(entries, "simple")
      assert length(filtered) == 1
      assert hd(filtered).parsed.module == "ExClaw.Simple.ModuleTest"
    end

    test "nil filter returns all entries" do
      parsed = TestCatalog.parse_file(@sample_test_file)
      entries = [%{parsed: parsed, file: "test/security/file_guard_test.exs"}]

      assert TestCatalog.filter(entries, nil) == entries
    end
  end

  describe "run/1 with --output" do
    @tag :tmp_dir
    test "writes catalog to file", %{tmp_dir: tmp_dir} do
      test_dir = Path.join(tmp_dir, "test")
      File.mkdir_p!(test_dir)
      File.write!(Path.join(test_dir, "sample_test.exs"), @sample_test_file)

      output_path = Path.join(tmp_dir, "catalog.md")
      TestCatalog.generate(test_dir, output: output_path)

      assert File.exists?(output_path)
      content = File.read!(output_path)
      assert content =~ "# ExClaw Test Catalog"
      assert content =~ "Security.FileGuard"
    end
  end
end
