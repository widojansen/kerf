defmodule Kerf.Tools.Dispatcher do
  @moduledoc """
  Routes tool calls to the appropriate tool module via the Tool Registry
  and builds the `tool_executor` closure for Agent.Session injection.
  """

  alias Kerf.Tools.Registry, as: ToolRegistry

  @doc """
  Dispatch a tool call to the appropriate handler via Registry lookup.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def dispatch(tool_name, input, opts) do
    registry = Keyword.get(opts, :registry, ToolRegistry)

    case ToolRegistry.get_tool(registry, tool_name) do
      {:ok, %{module: mod, function: fun}} ->
        apply(mod, fun, [input, opts])

      {:error, :not_found} ->
        {:error, "unknown tool: #{tool_name}"}
    end
  end

  @doc """
  Build a `tool_executor` function suitable for injection into Agent.Session.

  The returned function has the signature `fn(tool_name, input) -> {:ok, result} | {:error, reason}`.
  """
  def build_executor(opts) do
    fn tool_name, input ->
      dispatch(tool_name, input, opts)
    end
  end

  @doc """
  Returns tool definitions in Anthropic API format from the Registry.
  """
  def tool_definitions(opts \\ []) do
    registry = Keyword.get(opts, :registry, ToolRegistry)
    ToolRegistry.tool_definitions(registry)
  end
end
