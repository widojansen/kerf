defmodule ExClaw.Memory.Supervisor do
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    store_name = Keyword.get(opts, :store_name, ExClaw.Memory.Store)
    data_dir = Keyword.get(opts, :data_dir)
    repo = Keyword.get(opts, :repo, ExClaw.Repo)

    children = [
      {ExClaw.Memory.Store, name: store_name, data_dir: data_dir, repo: repo}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
