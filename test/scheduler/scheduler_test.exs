defmodule ExClaw.Scheduler.SchedulerTest do
  use ExClaw.DataCase

  alias ExClaw.Scheduler.Scheduler
  alias ExClaw.Scheduler.ScheduledTask

  setup do

    # Unique names to avoid collisions between tests
    suffix = System.unique_integer([:positive])
    scheduler_name = :"scheduler_#{suffix}"
    agent_sup_name = :"agent_sup_#{suffix}"
    registry_name = :"registry_#{suffix}"
    task_runner_name = :"task_runner_#{suffix}"

    # Start a DynamicSupervisor as a stand-in for Agent.Supervisor
    {:ok, _} = DynamicSupervisor.start_link(name: agent_sup_name, strategy: :one_for_one)

    # Start a Registry for session lookups
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    # Start a Task.Supervisor for running scheduled tasks
    {:ok, _} = Task.Supervisor.start_link(name: task_runner_name)

    # Canned LLM response — always returns a simple text response
    canned_response = fn _conn ->
      body = Jason.encode!(%{
        "content" => [%{"type" => "text", "text" => "Scheduled task result"}],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
        "model" => "claude-sonnet-4-20250514",
        "role" => "assistant"
      })
      {200, [{"content-type", "application/json"}], body}
    end

    # Start LLM infrastructure with unique names
    provider_name = :"provider_#{suffix}"
    rate_limiter_name = :"rate_limiter_#{suffix}"

    {:ok, rl_pid} =
      ExClaw.LLM.RateLimiter.start_link(
        name: rate_limiter_name,
        max_requests_per_minute: 1000,
        max_tokens_per_minute: 1_000_000
      )

    # Create a Req adapter that returns canned responses
    adapter = fn request ->
      {status, headers, body} = canned_response.(request)
      {request, Req.Response.new(status: status, headers: headers, body: body)}
    end

    {:ok, prov_pid} =
      ExClaw.LLM.Provider.start_link(
        name: provider_name,
        api_key: "test-key",
        base_url: "https://api.anthropic.com/v1",
        anthropic_version: "2023-06-01",
        adapter: adapter,
        rate_limiter: rate_limiter_name
      )

    allow_repo(rl_pid)
    allow_repo(prov_pid)

    {:ok, sched_pid} =
      Scheduler.start_link(
        name: scheduler_name,
        repo: ExClaw.Repo,
        agent_sup: agent_sup_name,
        registry: registry_name,
        task_runner: task_runner_name,
        agent_opts: [provider: provider_name, model: "claude-sonnet-4-20250514", rate_limiter: rate_limiter_name]
      )

    allow_repo(sched_pid)

    %{
      scheduler: scheduler_name,
      scheduler_pid: sched_pid,
      agent_sup: agent_sup_name,
      registry: registry_name,
      task_runner: task_runner_name,
      provider: provider_name
    }
  end

  describe "add_task/2" do
    test "inserts and returns a scheduled task", %{scheduler: scheduler} do
      attrs = %{
        group_id: "test-group",
        prompt: "Check the weather",
        schedule_type: "interval",
        schedule_value: "60000"
      }

      assert {:ok, %ScheduledTask{} = task} = Scheduler.add_task(scheduler, attrs)
      assert task.group_id == "test-group"
      assert task.prompt == "Check the weather"
      assert task.schedule_type == "interval"
      assert task.status == "active"
      assert task.next_run != nil
    end

    test "rejects invalid attributes", %{scheduler: scheduler} do
      attrs = %{
        group_id: "test-group",
        prompt: "Bad cron",
        schedule_type: "cron",
        schedule_value: "not valid"
      }

      assert {:error, %Ecto.Changeset{}} = Scheduler.add_task(scheduler, attrs)
    end
  end

  describe "remove_task/2" do
    test "deletes an existing task", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "g1",
          prompt: "test",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      assert :ok = Scheduler.remove_task(scheduler, task.id)
      assert {:error, :not_found} = Scheduler.get_task(scheduler, task.id)
    end

    test "returns error for non-existent task", %{scheduler: scheduler} do
      assert {:error, :not_found} = Scheduler.remove_task(scheduler, 999_999)
    end
  end

  describe "list_tasks/1" do
    test "returns all tasks", %{scheduler: scheduler} do
      Scheduler.add_task(scheduler, %{
        group_id: "g1",
        prompt: "t1",
        schedule_type: "interval",
        schedule_value: "60000"
      })

      Scheduler.add_task(scheduler, %{
        group_id: "g2",
        prompt: "t2",
        schedule_type: "interval",
        schedule_value: "120000"
      })

      assert {:ok, tasks} = Scheduler.list_tasks(scheduler)
      assert length(tasks) == 2
    end
  end

  describe "get_task/2" do
    test "returns a specific task", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "g1",
          prompt: "t1",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      assert {:ok, %ScheduledTask{id: id}} = Scheduler.get_task(scheduler, task.id)
      assert id == task.id
    end
  end

  describe "pause_task/2 and resume_task/2" do
    test "pause changes status to paused", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "g1",
          prompt: "t1",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      assert :ok = Scheduler.pause_task(scheduler, task.id)
      assert {:ok, paused} = Scheduler.get_task(scheduler, task.id)
      assert paused.status == "paused"
    end

    test "resume reactivates paused task", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "g1",
          prompt: "t1",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      :ok = Scheduler.pause_task(scheduler, task.id)
      assert :ok = Scheduler.resume_task(scheduler, task.id)
      assert {:ok, resumed} = Scheduler.get_task(scheduler, task.id)
      assert resumed.status == "active"
      assert resumed.next_run != nil
    end

    test "resume returns error for non-paused task", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "g1",
          prompt: "t1",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      assert {:error, :not_paused} = Scheduler.resume_task(scheduler, task.id)
    end
  end

  describe "firing and execution" do
    test "fire_now triggers immediate execution and logs result", %{
      scheduler: scheduler
    } do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "fire-test",
          prompt: "Hello scheduler",
          schedule_type: "interval",
          schedule_value: "3600000"
        })

      # Allow any task processes to use our sandbox connection
      Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, {:shared, self()})

      assert :ok = Scheduler.fire_now(scheduler, task.id)

      # Wait for async task execution to complete
      Process.sleep(500)

      assert {:ok, logs} = Scheduler.get_run_history(scheduler, task.id)
      assert length(logs) >= 1
      [log | _] = logs
      assert log.status == "success"
      assert log.duration_ms >= 0
    end

    test "once task auto-completes after execution", %{
      scheduler: scheduler
    } do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "once-test",
          prompt: "One shot",
          schedule_type: "once",
          schedule_value: ""
        })

      Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, {:shared, self()})

      :ok = Scheduler.fire_now(scheduler, task.id)
      Process.sleep(500)

      assert {:ok, completed_task} = Scheduler.get_task(scheduler, task.id)
      assert completed_task.status == "completed"
    end

    test "interval task reschedules after firing", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "interval-test",
          prompt: "Recurring",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, {:shared, self()})

      :ok = Scheduler.fire_now(scheduler, task.id)
      Process.sleep(500)

      assert {:ok, updated} = Scheduler.get_task(scheduler, task.id)
      assert updated.status == "active"
      # next_run should have been updated
      assert updated.last_run != nil
    end
  end

  describe "get_run_history/3" do
    test "returns empty list for task with no runs", %{scheduler: scheduler} do
      {:ok, task} =
        Scheduler.add_task(scheduler, %{
          group_id: "g1",
          prompt: "t1",
          schedule_type: "interval",
          schedule_value: "60000"
        })

      assert {:ok, []} = Scheduler.get_run_history(scheduler, task.id)
    end
  end
end
