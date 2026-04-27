defmodule Kerf.Dashboard.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      Kerf.Dashboard.EventLog,
      Kerf.Dashboard.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
