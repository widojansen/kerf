defmodule ExClaw.Security.FileGuard do
  @moduledoc """
  Validates file paths to prevent directory traversal and
  access to sensitive system files.
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
