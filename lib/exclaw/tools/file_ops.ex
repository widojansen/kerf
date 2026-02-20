defmodule ExClaw.Tools.FileOps do
  @moduledoc """
  File read/write tools operating on the host filesystem
  within the group's bind-mounted workspace directory.

  Path traversal is prevented by resolving paths and checking
  they remain inside the workspace.
  """

  @doc """
  Read a file from the group's workspace.

  Input: `%{"path" => relative_path}`
  """
  def read(input, opts) do
    with {:ok, path} <- extract_path(input),
         {:ok, full_path} <- resolve_safe_path(path, opts) do
      case File.read(full_path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, "file not found: #{path}"}
        {:error, reason} -> {:error, "read error: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Write a file to the group's workspace.

  Input: `%{"path" => relative_path, "content" => file_content}`
  """
  def write(input, opts) do
    with {:ok, path} <- extract_path(input),
         {:ok, content} <- extract_content(input),
         {:ok, full_path} <- resolve_safe_path(path, opts) do
      dir = Path.dirname(full_path)
      File.mkdir_p!(dir)

      case File.write(full_path, content) do
        :ok -> {:ok, "file written: #{path}"}
        {:error, reason} -> {:error, "write error: #{inspect(reason)}"}
      end
    end
  end

  # --- Private ---

  defp extract_path(%{"path" => path}) when is_binary(path) and byte_size(path) > 0, do: {:ok, path}
  defp extract_path(_), do: {:error, "missing or invalid 'path' parameter"}

  defp extract_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp extract_content(_), do: {:error, "missing or invalid 'content' parameter"}

  defp resolve_safe_path(path, opts) do
    workspaces_dir = Keyword.fetch!(opts, :workspaces_dir)
    group_id = Keyword.fetch!(opts, :group_id)
    safe_group = sanitize_group_id(group_id)

    workspace = Path.join(workspaces_dir, safe_group) |> Path.expand()
    full_path = Path.join(workspace, path) |> Path.expand()

    if String.starts_with?(full_path, workspace <> "/") or full_path == workspace do
      {:ok, full_path}
    else
      {:error, "path traversal denied: path resolves outside workspace"}
    end
  end

  defp sanitize_group_id(group_id) do
    String.replace(group_id, ~r/[^a-zA-Z0-9_\-]/, "_")
  end
end
