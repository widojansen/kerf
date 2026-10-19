defmodule Kerf.Decide.Supervisor do
  @moduledoc """
  SPEC_H Decide subtree (non_functional: own supervisor, :rest_for_one).

  Kerf.Decide.TaskSupervisor runs every Kerf.Decide.Server request, so a
  stalled or crashing adapter is isolated from the servers asking it (F02.2).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Kerf.Decide.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
