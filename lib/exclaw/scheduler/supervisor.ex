defmodule ExClaw.Scheduler.Supervisor do
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    scheduler_name = Keyword.get(opts, :scheduler_name, ExClaw.Scheduler.Scheduler)
    task_runner_name = Keyword.get(opts, :task_runner_name, ExClaw.Scheduler.TaskRunner)
    repo = Keyword.get(opts, :repo, ExClaw.Repo)
    agent_sup = Keyword.get(opts, :agent_sup, ExClaw.Agent.Supervisor)
    registry = Keyword.get(opts, :registry, ExClaw.SessionRegistry)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    children = [
      {Task.Supervisor, name: task_runner_name},
      {ExClaw.Scheduler.Scheduler,
       name: scheduler_name,
       repo: repo,
       agent_sup: agent_sup,
       registry: registry,
       task_runner: task_runner_name,
       agent_opts: agent_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
