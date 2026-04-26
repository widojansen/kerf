defmodule Kerf.Container.Supervisor do
  @moduledoc """
  Supervises the Container.Manager.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    manager_opts = Keyword.get(opts, :manager_opts, [])

    children = [
      {Kerf.Container.Manager, manager_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
