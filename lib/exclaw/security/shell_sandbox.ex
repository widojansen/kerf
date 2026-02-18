defmodule ExClaw.Security.ShellSandbox do
  @moduledoc """
  Filters shell commands to block dangerous operations.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(_tool_name, _input) do
    # TODO: Implement security checks
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}
end
