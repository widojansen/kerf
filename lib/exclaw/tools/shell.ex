defmodule ExClaw.Tools.Shell do
  @moduledoc """
  Shell execution tool that runs commands inside a Docker container
  managed by Container.Manager.
  """

  alias ExClaw.Container.Manager

  @doc """
  Execute a shell command in the group's container.

  Input: `%{"command" => command_string}`
  """
  def execute(input, opts) do
    with {:ok, command} <- extract_command(input) do
      manager = Keyword.fetch!(opts, :container_manager)
      group_id = Keyword.fetch!(opts, :group_id)
      exec_opts = Keyword.take(opts, [:timeout])

      Manager.exec(manager, group_id, command, exec_opts)
    end
  end

  defp extract_command(%{"command" => cmd}) when is_binary(cmd) and byte_size(cmd) > 0, do: {:ok, cmd}
  defp extract_command(_), do: {:error, "missing or invalid 'command' parameter"}
end
