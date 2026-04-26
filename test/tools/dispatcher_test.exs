defmodule Kerf.Tools.DispatcherTest do
  use ExUnit.Case, async: true

  alias Kerf.Tools.Dispatcher
  alias Kerf.Tools.Registry, as: ToolRegistry
  alias Kerf.Tools.Registrations

  defp start_registry do
    name = :"disp_reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ToolRegistry.start_link(name: name)
    name
  end

  defp start_mock_manager(registry) do
    workspaces_dir = System.tmp_dir!() |> Path.join("exclaw_disp_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(workspaces_dir)

    adapter = fn args ->
      case args do
        ["create" | _] -> {"container_abc\n", 0}
        ["start" | _] -> {"container_abc\n", 0}
        ["inspect" | _] -> {"true\n", 0}
        ["exec" | rest] ->
          command = List.last(rest)
          {"executed: #{command}\n", 0}
        _ -> {"", 0}
      end
    end

    {:ok, pid} = Kerf.Container.Manager.start_link(
      workspaces_dir: workspaces_dir,
      image: "exclaw-sandbox:latest",
      docker_adapter: adapter,
      exec_timeout: 5_000,
      max_output_size: 102_400,
      container_opts: []
    )

    # Register built-in tools into this test's registry
    Registrations.register_builtins(registry)

    on_exit(fn -> File.rm_rf(workspaces_dir) end)
    {pid, workspaces_dir}
  end

  describe "dispatch/3" do
    test "routes shell_exec to Shell module" do
      reg = start_registry()
      {manager, _dir} = start_mock_manager(reg)
      opts = [container_manager: manager, group_id: "test_group", workspaces_dir: "/tmp", registry: reg]

      assert {:ok, output} = Dispatcher.dispatch("shell_exec", %{"command" => "echo hi"}, opts)
      assert output =~ "echo hi"
    end

    test "routes file_read to FileOps module" do
      reg = start_registry()
      {_manager, workspaces_dir} = start_mock_manager(reg)

      # Create a file in the workspace
      group_dir = Path.join(workspaces_dir, "test_group")
      File.mkdir_p!(group_dir)
      File.write!(Path.join(group_dir, "test.txt"), "file content")

      opts = [container_manager: nil, group_id: "test_group", workspaces_dir: workspaces_dir, registry: reg]
      assert {:ok, "file content"} = Dispatcher.dispatch("file_read", %{"path" => "test.txt"}, opts)
    end

    test "routes file_write to FileOps module" do
      reg = start_registry()
      {_manager, workspaces_dir} = start_mock_manager(reg)

      group_dir = Path.join(workspaces_dir, "test_group")
      File.mkdir_p!(group_dir)

      opts = [container_manager: nil, group_id: "test_group", workspaces_dir: workspaces_dir, registry: reg]
      assert {:ok, _msg} = Dispatcher.dispatch("file_write", %{"path" => "new.txt", "content" => "data"}, opts)
      assert File.read!(Path.join(group_dir, "new.txt")) == "data"
    end

    test "returns error for unknown tool" do
      reg = start_registry()
      Registrations.register_builtins(reg)
      opts = [container_manager: nil, group_id: "test_group", workspaces_dir: "/tmp", registry: reg]
      assert {:error, reason} = Dispatcher.dispatch("unknown_tool", %{}, opts)
      assert reason =~ "unknown tool"
    end
  end

  describe "build_executor/1" do
    test "returns a function that dispatches tool calls" do
      reg = start_registry()
      {manager, _dir} = start_mock_manager(reg)
      opts = [container_manager: manager, group_id: "test_group", workspaces_dir: "/tmp", registry: reg]

      executor = Dispatcher.build_executor(opts)
      assert is_function(executor, 2)

      assert {:ok, output} = executor.("shell_exec", %{"command" => "ls"})
      assert output =~ "ls"
    end
  end

  describe "tool_definitions/1" do
    test "returns Anthropic-format tool schemas from registry" do
      reg = start_registry()
      Registrations.register_builtins(reg)

      defs = Dispatcher.tool_definitions(registry: reg)
      assert is_list(defs)
      assert length(defs) == 5

      names = Enum.map(defs, & &1["name"])
      assert "shell_exec" in names
      assert "file_read" in names
      assert "file_write" in names
      assert "web_fetch" in names
      assert "web_search" in names

      # Each should have description and input_schema
      Enum.each(defs, fn tool ->
        assert Map.has_key?(tool, "name")
        assert Map.has_key?(tool, "description")
        assert Map.has_key?(tool, "input_schema")
      end)
    end
  end
end
