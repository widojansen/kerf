defmodule Kerf.Scheduler.SupervisorTest do
  use Kerf.DataCase

  alias Kerf.Scheduler.Supervisor, as: SchedulerSup
  alias Kerf.Scheduler.Scheduler

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Kerf.Repo, {:shared, self()})

    suffix = System.unique_integer([:positive])
    sup_name = :"sched_sup_#{suffix}"
    scheduler_name = :"scheduler_#{suffix}"
    task_runner_name = :"task_runner_#{suffix}"
    agent_sup_name = :"agent_sup_#{suffix}"
    registry_name = :"registry_#{suffix}"

    {:ok, _} = DynamicSupervisor.start_link(name: agent_sup_name, strategy: :one_for_one)
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    opts = [
      name: sup_name,
      scheduler_name: scheduler_name,
      task_runner_name: task_runner_name,
      repo: Kerf.Repo,
      agent_sup: agent_sup_name,
      registry: registry_name,
      agent_opts: []
    ]

    %{
      opts: opts,
      sup_name: sup_name,
      scheduler_name: scheduler_name,
      task_runner_name: task_runner_name
    }
  end

  test "starts TaskRunner and Scheduler under supervision", %{
    opts: opts,
    scheduler_name: scheduler_name,
    task_runner_name: task_runner_name
  } do
    {:ok, sup_pid} = SchedulerSup.start_link(opts)
    assert Process.alive?(sup_pid)

    # Both children should be running
    assert Process.whereis(task_runner_name) != nil
    assert Process.whereis(scheduler_name) != nil
  end

  test "restarts Scheduler on crash", %{
    opts: opts,
    scheduler_name: scheduler_name
  } do
    {:ok, _sup_pid} = SchedulerSup.start_link(opts)

    old_pid = Process.whereis(scheduler_name)
    assert old_pid != nil

    Process.exit(old_pid, :kill)
    Process.sleep(100)

    new_pid = Process.whereis(scheduler_name)
    assert new_pid != nil
    assert new_pid != old_pid
  end

  test "Scheduler reloads tasks from DB after restart", %{
    opts: opts,
    scheduler_name: scheduler_name
  } do
    {:ok, _sup_pid} = SchedulerSup.start_link(opts)

    # Add a task
    {:ok, task} =
      Scheduler.add_task(scheduler_name, %{
        group_id: "persist-test",
        prompt: "Survive restart",
        schedule_type: "interval",
        schedule_value: "60000"
      })

    # Kill the Scheduler
    old_pid = Process.whereis(scheduler_name)
    Process.exit(old_pid, :kill)
    Process.sleep(200)

    # Allow the new process to use our sandbox
    new_pid = Process.whereis(scheduler_name)
    assert new_pid != nil
    allow_repo(new_pid)

    # Task should be reloaded from DB
    assert {:ok, tasks} = Scheduler.list_tasks(scheduler_name)
    assert length(tasks) >= 1
    assert Enum.any?(tasks, fn t -> t.id == task.id end)
  end
end
