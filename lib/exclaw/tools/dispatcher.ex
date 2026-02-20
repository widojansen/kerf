defmodule ExClaw.Tools.Dispatcher do
  @moduledoc """
  Routes tool calls to the appropriate tool module and builds
  the `tool_executor` closure for Agent.Session injection.
  """

  alias ExClaw.Tools.{Shell, FileOps}

  @doc """
  Dispatch a tool call to the appropriate handler.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def dispatch("shell_exec", input, opts) do
    Shell.execute(input, opts)
  end

  def dispatch("file_read", input, opts) do
    FileOps.read(input, opts)
  end

  def dispatch("file_write", input, opts) do
    FileOps.write(input, opts)
  end

  def dispatch(tool_name, _input, _opts) do
    {:error, "unknown tool: #{tool_name}"}
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
  Returns tool definitions in Anthropic API format for the three built-in tools.
  """
  def tool_definitions do
    [
      %{
        "name" => "shell_exec",
        "description" => "Execute a shell command in a sandboxed Docker container. The command runs inside the group's isolated workspace.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "The shell command to execute"
            }
          },
          "required" => ["command"]
        }
      },
      %{
        "name" => "file_read",
        "description" => "Read the contents of a file from the workspace. Only files within the workspace directory can be accessed.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Relative path to the file within the workspace"
            }
          },
          "required" => ["path"]
        }
      },
      %{
        "name" => "file_write",
        "description" => "Write content to a file in the workspace. Creates intermediate directories as needed. Only files within the workspace directory can be written.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Relative path to the file within the workspace"
            },
            "content" => %{
              "type" => "string",
              "description" => "The content to write to the file"
            }
          },
          "required" => ["path", "content"]
        }
      }
    ]
  end
end
