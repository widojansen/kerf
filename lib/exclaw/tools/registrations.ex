defmodule ExClaw.Tools.Registrations do
  @moduledoc """
  Registers all built-in tools with the Tool Registry on startup.
  Single source of truth for tool definitions.
  """

  alias ExClaw.Tools.Registry, as: ToolRegistry

  @doc "Register all built-in tools with the given registry."
  def register_builtins(registry \\ ToolRegistry) do
    Enum.each(builtins(), &ToolRegistry.register_tool(registry, &1))
  end

  @doc "Return the list of built-in tool specs."
  def builtins do
    [
      %{
        name: "shell_exec",
        description: "Execute a shell command in a sandboxed Docker container. The command runs inside the group's isolated workspace.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "The shell command to execute"
            }
          },
          "required" => ["command"]
        },
        module: ExClaw.Tools.Shell,
        function: :execute
      },
      %{
        name: "file_read",
        description: "Read the contents of a file from the workspace. Only files within the workspace directory can be accessed.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Relative path to the file within the workspace"
            }
          },
          "required" => ["path"]
        },
        module: ExClaw.Tools.FileOps,
        function: :read
      },
      %{
        name: "file_write",
        description: "Write content to a file in the workspace. Creates intermediate directories as needed. Only files within the workspace directory can be written.",
        input_schema: %{
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
        },
        module: ExClaw.Tools.FileOps,
        function: :write
      },
      %{
        name: "web_fetch",
        description: "Fetch and extract readable content from a web URL. Returns the page title and main text content. Includes SSRF protection.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "description" => "The URL to fetch (http or https)"
            },
            "extract_mode" => %{
              "type" => "string",
              "enum" => ["text", "markdown"],
              "description" => "Content extraction mode (default: text)"
            }
          },
          "required" => ["url"]
        },
        module: ExClaw.Tools.WebFetch,
        function: :fetch
      },
      %{
        name: "web_search",
        description: "Search the web using a search engine. Returns a numbered list of results with titles, URLs, and descriptions.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "The search query"
            },
            "count" => %{
              "type" => "integer",
              "description" => "Number of results to return (default: 5, max: 10)"
            }
          },
          "required" => ["query"]
        },
        module: ExClaw.Tools.WebSearch,
        function: :search
      }
    ]
  end
end
