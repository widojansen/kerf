defmodule Kerf.Security.Supervisor do
  @moduledoc """
  Supervises all security GenServers:
  - FileGuard: path validation and traversal prevention
  - ShellSandbox: command filtering and dangerous command blocking
  - PromptGuard: prompt injection detection
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Kerf.Security.FileGuard,
      Kerf.Security.ShellSandbox,
      Kerf.Security.PromptGuard
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
