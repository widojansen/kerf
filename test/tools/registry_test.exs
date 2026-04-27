defmodule Kerf.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Kerf.Tools.Registry, as: ToolRegistry

  defp start_registry(_context \\ %{}) do
    name = :"tool_reg_#{System.unique_integer([:positive])}"
    {:ok, pid} = ToolRegistry.start_link(name: name)
    %{registry: name, pid: pid}
  end

  defp valid_tool_spec(overrides \\ %{}) do
    Map.merge(
      %{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{
          "type" => "object",
          "properties" => %{"input" => %{"type" => "string"}},
          "required" => ["input"]
        },
        module: Kerf.Tools.Shell,
        function: :execute
      },
      overrides
    )
  end

  describe "start_link/1" do
    test "starts the GenServer" do
      %{pid: pid} = start_registry()
      assert Process.alive?(pid)
    end
  end

  describe "register_tool/2" do
    test "registers a valid tool spec" do
      %{registry: reg} = start_registry()
      assert :ok = ToolRegistry.register_tool(reg, valid_tool_spec())
    end

    test "rejects spec with missing name" do
      %{registry: reg} = start_registry()
      spec = valid_tool_spec() |> Map.delete(:name)
      assert {:error, reason} = ToolRegistry.register_tool(reg, spec)
      assert reason =~ "name"
    end

    test "rejects spec with missing module" do
      %{registry: reg} = start_registry()
      spec = valid_tool_spec() |> Map.delete(:module)
      assert {:error, reason} = ToolRegistry.register_tool(reg, spec)
      assert reason =~ "module"
    end

    test "rejects spec with missing function" do
      %{registry: reg} = start_registry()
      spec = valid_tool_spec() |> Map.delete(:function)
      assert {:error, reason} = ToolRegistry.register_tool(reg, spec)
      assert reason =~ "function"
    end

    test "rejects spec with missing input_schema" do
      %{registry: reg} = start_registry()
      spec = valid_tool_spec() |> Map.delete(:input_schema)
      assert {:error, reason} = ToolRegistry.register_tool(reg, spec)
      assert reason =~ "input_schema"
    end

    test "re-registration updates the tool (idempotent)" do
      %{registry: reg} = start_registry()
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec())
      updated = valid_tool_spec(%{description: "Updated description"})
      assert :ok = ToolRegistry.register_tool(reg, updated)

      {:ok, tool} = ToolRegistry.get_tool(reg, "test_tool")
      assert tool.description == "Updated description"
    end
  end

  describe "get_tool/2" do
    test "returns spec for registered tool" do
      %{registry: reg} = start_registry()
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec())

      assert {:ok, tool} = ToolRegistry.get_tool(reg, "test_tool")
      assert tool.name == "test_tool"
      assert tool.module == Kerf.Tools.Shell
      assert tool.function == :execute
    end

    test "returns error for unregistered tool" do
      %{registry: reg} = start_registry()
      assert {:error, :not_found} = ToolRegistry.get_tool(reg, "nonexistent")
    end
  end

  describe "list_tools/1" do
    test "returns all registered tools" do
      %{registry: reg} = start_registry()
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec(%{name: "tool_a"}))
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec(%{name: "tool_b"}))

      tools = ToolRegistry.list_tools(reg)
      names = Enum.map(tools, & &1.name)
      assert "tool_a" in names
      assert "tool_b" in names
      assert length(tools) == 2
    end

    test "returns empty list when no tools registered" do
      %{registry: reg} = start_registry()
      assert ToolRegistry.list_tools(reg) == []
    end
  end

  describe "unregister_tool/2" do
    test "removes a registered tool" do
      %{registry: reg} = start_registry()
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec())
      assert :ok = ToolRegistry.unregister_tool(reg, "test_tool")
      assert {:error, :not_found} = ToolRegistry.get_tool(reg, "test_tool")
    end

    test "returns error for non-existent tool" do
      %{registry: reg} = start_registry()
      assert {:error, :not_found} = ToolRegistry.unregister_tool(reg, "nonexistent")
    end
  end

  describe "tool_definitions/1" do
    test "returns Anthropic-format list" do
      %{registry: reg} = start_registry()
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec())

      defs = ToolRegistry.tool_definitions(reg)
      assert is_list(defs)
      assert length(defs) == 1

      [tool_def] = defs
      assert tool_def["name"] == "test_tool"
      assert tool_def["description"] == "A test tool"
      assert is_map(tool_def["input_schema"])
    end

    test "returns empty list when no tools registered" do
      %{registry: reg} = start_registry()
      assert ToolRegistry.tool_definitions(reg) == []
    end
  end

  describe "clear/1" do
    test "empties the registry" do
      %{registry: reg} = start_registry()
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec(%{name: "tool_a"}))
      :ok = ToolRegistry.register_tool(reg, valid_tool_spec(%{name: "tool_b"}))
      assert length(ToolRegistry.list_tools(reg)) == 2

      assert :ok = ToolRegistry.clear(reg)
      assert ToolRegistry.list_tools(reg) == []
    end
  end
end
