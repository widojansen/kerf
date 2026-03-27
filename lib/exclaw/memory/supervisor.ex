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

    embedder_config = Application.get_env(:exclaw, ExClaw.Memory.Embedder, [])
    embedder_enabled = Keyword.get(embedder_config, :enabled, true)

    embedder_children =
      if embedder_enabled do
        [
          {Task.Supervisor, name: ExClaw.Memory.TaskSupervisor},
          {ExClaw.Memory.Embedder, Keyword.put(embedder_config, :name, ExClaw.Memory.Embedder)}
        ]
      else
        []
      end

    store_opts =
      [name: store_name, data_dir: data_dir, repo: repo] ++
        if embedder_enabled do
          [embedder: ExClaw.Memory.Embedder, task_supervisor: ExClaw.Memory.TaskSupervisor]
        else
          []
        end

    children = embedder_children ++ [{ExClaw.Memory.Store, store_opts}]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
