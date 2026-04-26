defmodule Kerf.Memory.Supervisor do
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    store_name = Keyword.get(opts, :store_name, Kerf.Memory.Store)
    data_dir = Keyword.get(opts, :data_dir)
    repo = Keyword.get(opts, :repo, Kerf.Repo)

    embedder_config = Application.get_env(:kerf, Kerf.Memory.Embedder, [])
    embedder_enabled = Keyword.get(embedder_config, :enabled, true)

    embedder_children =
      if embedder_enabled do
        [
          {Task.Supervisor, name: Kerf.Memory.TaskSupervisor},
          {Kerf.Memory.Embedder, Keyword.put(embedder_config, :name, Kerf.Memory.Embedder)}
        ]
      else
        []
      end

    store_opts =
      [name: store_name, data_dir: data_dir, repo: repo] ++
        if embedder_enabled do
          [embedder: Kerf.Memory.Embedder, task_supervisor: Kerf.Memory.TaskSupervisor]
        else
          []
        end

    children = embedder_children ++ [{Kerf.Memory.Store, store_opts}]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
