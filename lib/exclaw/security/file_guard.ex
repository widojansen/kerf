defmodule ExClaw.Security.FileGuard do
  @moduledoc """
  Validates file paths to prevent directory traversal and
  access to sensitive system files.
  """
  use GenServer

  @file_tools ~w[file_read file_write]

  @sensitive_dotfiles ~w[.env .ssh .aws .gnupg .netrc .npmrc .pypirc]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Only file_read and file_write need path validation; all other tools pass through.
  def check(tool_name, _input) when tool_name not in @file_tools, do: :ok

  def check(tool_name, %{path: path}) do
    result =
      with :ok <- check_null_bytes(path),
           :ok <- check_url_encoded_traversal(path),
           :ok <- check_home_directory(path),
           normalized = normalize(path),
           :ok <- check_traversal(normalized),
           :ok <- check_absolute_outside_workspace(normalized),
           :ok <- check_sensitive_dotfiles(normalized) do
        :ok
      end

    maybe_log_denial(result, "FileGuard", %{tool: tool_name, path: path})
    result
  end

  # --- private checks ---

  # Null bytes are used to truncate paths at the C-library level:
  # "/workspace/safe.txt\0/../etc/passwd" looks safe to Elixir string
  # functions but the OS sees only "/workspace/safe.txt". Reject any path
  # that contains a null byte before doing anything else.
  defp check_null_bytes(path) do
    if String.contains?(path, <<0>>),
      do: {:denied, "null byte injection detected"},
      else: :ok
  end

  # URL-encoding can disguise traversal sequences that a naive ".." check
  # would miss: "%2F..%2F" decodes to "/../". We decode first, then look
  # for traversal — before normalization strips it away.
  defp check_url_encoded_traversal(path) do
    decoded = URI.decode(path)
    if String.contains?(decoded, ".."),
      do: {:denied, "path traversal via URL encoding detected"},
      else: :ok
  end

  # "~/" is a shell expansion shorthand for the user's home directory.
  # The OS does not expand it, but agent-generated paths might use it
  # intentionally to target ~/.ssh, ~/.aws, etc.
  defp check_home_directory(path) do
    if String.starts_with?(path, "~/"),
      do: {:denied, "access to home directory is not allowed"},
      else: :ok
  end

  # Resolve "." and ".." segments purely in memory, without touching the
  # filesystem. This mirrors what the OS would do, giving us the true
  # destination path to validate against our allow-list.
  defp normalize(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn
      "..", [_ | rest] -> rest   # pop one level up
      "..", []         -> []     # already at root — no-op
      ".",  acc        -> acc    # current dir — skip
      segment,  acc   -> [segment | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  # After normalization any surviving ".." means the path attempted to
  # escape past the root (e.g. the original had more ".." than depth).
  defp check_traversal(path) do
    if String.contains?(path, ".."),
      do: {:denied, "path traversal detected"},
      else: :ok
  end

  # Relative paths (no leading "/") are allowed — they are implicitly
  # scoped to the working directory inside the sandbox container.
  # Absolute paths are only allowed when they stay within /workspace.
  defp check_absolute_outside_workspace(path) do
    cond do
      not String.starts_with?(path, "/")    -> :ok
      String.starts_with?(path, "/workspace") -> :ok
      true -> {:denied, "absolute path outside /workspace is not allowed"}
    end
  end

  # Block any path segment that matches a known secrets directory or file.
  # Checked by segment (not substring) so that a file named "not-.env" is
  # not accidentally caught.
  defp check_sensitive_dotfiles(path) do
    segments = String.split(path, "/")

    blocked = Enum.any?(segments, fn segment ->
      Enum.any?(@sensitive_dotfiles, fn dotfile ->
        segment == dotfile or String.starts_with?(segment, dotfile <> "/")
      end)
    end)

    if blocked,
      do: {:denied, "access to sensitive dotfile is not allowed"},
      else: :ok
  end

  defp maybe_log_denial({:denied, reason}, module, input_preview) do
    try do
      ExClaw.Dashboard.EventLog.log(:security_denial, %{
        module: module,
        reason: reason,
        input_preview: String.slice(inspect(input_preview), 0, 200),
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    end
  end

  defp maybe_log_denial(:ok, _module, _input), do: :ok

  @impl true
  def init(_opts), do: {:ok, %{}}
end
