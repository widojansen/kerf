defmodule ExClaw.Scheduler.Scheduler do
  use GenServer

  alias ExClaw.Scheduler.ScheduledTask
  alias ExClaw.Scheduler.TaskRunLog

  import Ecto.Query

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def add_task(name \\ __MODULE__, attrs) do
    GenServer.call(name, {:add_task, attrs})
  end

  def remove_task(name \\ __MODULE__, task_id) do
    GenServer.call(name, {:remove_task, task_id})
  end

  def pause_task(name \\ __MODULE__, task_id) do
    GenServer.call(name, {:pause_task, task_id})
  end

  def resume_task(name \\ __MODULE__, task_id) do
    GenServer.call(name, {:resume_task, task_id})
  end

  def list_tasks(name \\ __MODULE__) do
    GenServer.call(name, :list_tasks)
  end

  def get_task(name \\ __MODULE__, task_id) do
    GenServer.call(name, {:get_task, task_id})
  end

  def get_run_history(name \\ __MODULE__, task_id, opts \\ []) do
    GenServer.call(name, {:get_run_history, task_id, opts})
  end

  def fire_now(name \\ __MODULE__, task_id) do
    GenServer.call(name, {:fire_now, task_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    agent_sup = Keyword.fetch!(opts, :agent_sup)
    registry = Keyword.fetch!(opts, :registry)
    task_runner = Keyword.fetch!(opts, :task_runner)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    state = %{
      tasks: %{},
      timers: %{},
      repo: repo,
      agent_sup: agent_sup,
      registry: registry,
      task_runner: task_runner,
      agent_opts: agent_opts
    }

    # Load active tasks from DB and schedule them
    state = load_tasks_from_db(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:add_task, attrs}, _from, state) do
    changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)

    case state.repo.insert(changeset) do
      {:ok, task} ->
        next_run = compute_next_run(task)
        task = update_next_run_in_db(state.repo, task, next_run)
        state = schedule_task(state, task)
        {:reply, {:ok, task}, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  rescue
    e -> {:reply, {:error, Exception.message(e)}, state}
  end

  @impl true
  def handle_call({:remove_task, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _task ->
        cancel_timer(state, task_id)

        try do
          from(t in ScheduledTask, where: t.id == ^task_id)
          |> state.repo.delete_all()
        rescue
          _ -> :ok
        end

        state = %{
          state
          | tasks: Map.delete(state.tasks, task_id),
            timers: Map.delete(state.timers, task_id)
        }

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:pause_task, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        cancel_timer(state, task_id)
        task = %{task | status: "paused"}

        try do
          state.repo.update(ScheduledTask.changeset(task, %{status: "paused"}))
        rescue
          _ -> :ok
        end

        state = %{
          state
          | tasks: Map.put(state.tasks, task_id, task),
            timers: Map.delete(state.timers, task_id)
        }

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:resume_task, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: "paused"} = task ->
        next_run = compute_next_run(task)
        task = %{task | status: "active", next_run: next_run}

        try do
          state.repo.update(
            ScheduledTask.changeset(task, %{status: "active", next_run: next_run})
          )
        rescue
          _ -> :ok
        end

        state = schedule_task(state, task)
        {:reply, :ok, state}

      _task ->
        {:reply, {:error, :not_paused}, state}
    end
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks = Map.values(state.tasks)
    {:reply, {:ok, tasks}, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil -> {:reply, {:error, :not_found}, state}
      task -> {:reply, {:ok, task}, state}
    end
  end

  @impl true
  def handle_call({:get_run_history, task_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)

    result =
      try do
        logs =
          from(l in TaskRunLog,
            where: l.task_id == ^task_id,
            order_by: [desc: l.started_at],
            limit: ^limit
          )
          |> state.repo.all()

        {:ok, logs}
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:fire_now, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        execute_task(state, task)
        state = reschedule_after_fire(state, task)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:fire, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      %{status: "paused"} ->
        {:noreply, state}

      task ->
        execute_task(state, task)
        state = reschedule_after_fire(state, task)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_completed, task_id, outcome}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        task = %{task | last_run: now, last_result: format_outcome(outcome)}

        # For once/at, mark as completed
        task =
          if task.schedule_type in ["once", "at"] do
            %{task | status: "completed"}
          else
            task
          end

        try do
          state.repo.update(
            ScheduledTask.changeset(task, %{
              last_run: task.last_run,
              last_result: task.last_result,
              status: task.status
            })
          )
        rescue
          _ -> :ok
        end

        state =
          if task.status == "completed" do
            %{
              state
              | tasks: Map.put(state.tasks, task_id, task),
                timers: Map.delete(state.timers, task_id)
            }
          else
            %{state | tasks: Map.put(state.tasks, task_id, task)}
          end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp load_tasks_from_db(state) do
    try do
      tasks =
        from(t in ScheduledTask, where: t.status == "active")
        |> state.repo.all()

      Enum.reduce(tasks, state, fn task, acc ->
        schedule_task(acc, task)
      end)
    rescue
      _ -> state
    end
  end

  defp schedule_task(state, task) do
    delay = compute_delay(task.next_run)
    timer_ref = Process.send_after(self(), {:fire, task.id}, max(delay, 0))

    %{
      state
      | tasks: Map.put(state.tasks, task.id, task),
        timers: Map.put(state.timers, task.id, timer_ref)
    }
  end

  defp cancel_timer(state, task_id) do
    case Map.get(state.timers, task_id) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end
  end

  defp compute_delay(nil), do: 0

  defp compute_delay(next_run) do
    now = DateTime.utc_now()
    DateTime.diff(next_run, now, :millisecond)
  end

  defp compute_next_run(%{schedule_type: "cron", schedule_value: cron_expr}) do
    case Crontab.CronExpression.Parser.parse(cron_expr) do
      {:ok, expr} ->
        naive_now = NaiveDateTime.utc_now()

        case Crontab.Scheduler.get_next_run_date(expr, naive_now) do
          {:ok, naive_dt} ->
            DateTime.from_naive!(naive_dt, "Etc/UTC") |> DateTime.truncate(:second)

          _ ->
            DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
        end

      _ ->
        DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
    end
  end

  defp compute_next_run(%{schedule_type: "interval", schedule_value: ms_str}) do
    {ms, _} = Integer.parse(ms_str)
    DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.truncate(:second)
  end

  defp compute_next_run(%{schedule_type: "once"}) do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp compute_next_run(%{schedule_type: "at", schedule_value: iso_str}) do
    case DateTime.from_iso8601(iso_str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp compute_next_run(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp update_next_run_in_db(repo, task, next_run) do
    task = %{task | next_run: next_run}

    try do
      case repo.update(ScheduledTask.changeset(task, %{next_run: next_run})) do
        {:ok, updated} -> updated
        _ -> task
      end
    rescue
      _ -> task
    end
  end

  defp execute_task(state, task) do
    scheduler_pid = self()
    task_id = task.id

    effective_group_id =
      case task.context_mode do
        "group" -> task.group_id
        _ -> "scheduler:#{task_id}:#{System.unique_integer([:positive])}"
      end

    Task.Supervisor.start_child(state.task_runner, fn ->
      started_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {status, result, error} =
        try do
          case ExClaw.Agent.Supervisor.handle_message(
                 state.agent_sup,
                 state.registry,
                 effective_group_id,
                 task.prompt,
                 state.agent_opts
               ) do
            {:ok, text} -> {"success", text, nil}
            {:error, reason} -> {"error", nil, inspect(reason)}
          end
        rescue
          e -> {"error", nil, Exception.message(e)}
        end

      duration_ms =
        DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
        |> max(0)

      try do
        %TaskRunLog{}
        |> TaskRunLog.changeset(%{
          task_id: task_id,
          started_at: started_at,
          duration_ms: duration_ms,
          status: status,
          result: result,
          error: error
        })
        |> state.repo.insert()
      rescue
        _ -> :ok
      end

      send(scheduler_pid, {:task_completed, task_id, {status, result, error}})
    end)
  end

  defp reschedule_after_fire(state, task) do
    case task.schedule_type do
      type when type in ["cron", "interval"] ->
        next_run = compute_next_run(task)
        updated_task = update_next_run_in_db(state.repo, task, next_run)
        updated_task = %{updated_task | next_run: next_run}

        cancel_timer(state, task.id)
        delay = compute_delay(next_run)
        timer_ref = Process.send_after(self(), {:fire, task.id}, max(delay, 0))

        %{
          state
          | tasks: Map.put(state.tasks, task.id, updated_task),
            timers: Map.put(state.timers, task.id, timer_ref)
        }

      _ ->
        # once/at — timer removed, completion handled in :task_completed
        %{state | timers: Map.delete(state.timers, task.id)}
    end
  end

  defp format_outcome({"success", result, _}), do: result
  defp format_outcome({"error", _, error}), do: "ERROR: #{error}"
  defp format_outcome(_), do: nil
end
