defmodule Kerf.Monitor.ProcessHealth do
  @moduledoc """
  Periodic health checker for critical named processes.

  Inspects each watched process for liveness, message queue depth,
  and memory usage. Emits `:telemetry` events for anomalies.
  """
  use GenServer

  require Logger

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns a map of process_name => :ok | :down | {:degraded, reason}."
  def status(name) do
    GenServer.call(name, :status)
  end

  @doc "Add a process to the watch list at runtime."
  def add_watch(name, process_name) do
    GenServer.call(name, {:add_watch, process_name})
  end

  @doc "Remove a process from the watch list at runtime."
  def remove_watch(name, process_name) do
    GenServer.call(name, {:remove_watch, process_name})
  end

  @doc "Trigger an immediate health check (for testing)."
  def check_now(name) do
    GenServer.call(name, :check_now)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    watched = Keyword.get(opts, :watched, [])
    interval_ms = Keyword.get(opts, :interval_ms, 30_000)
    queue_high = Keyword.get(opts, :queue_high_threshold, 100)
    memory_high_mb = Keyword.get(opts, :memory_high_threshold_mb, 256)

    timer_ref = schedule_tick(interval_ms)

    state = %{
      watched: watched,
      interval_ms: interval_ms,
      thresholds: %{queue_high: queue_high, memory_high_mb: memory_high_mb},
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call({:add_watch, process_name}, _from, state) do
    state = %{state | watched: Enum.uniq([process_name | state.watched])}
    {:reply, :ok, state}
  end

  def handle_call({:remove_watch, process_name}, _from, state) do
    state = %{state | watched: List.delete(state.watched, process_name)}
    {:reply, :ok, state}
  end

  def handle_call(:check_now, _from, state) do
    run_check(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_check(state)
    timer_ref = schedule_tick(state.interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_tick(:manual), do: nil

  defp schedule_tick(ms) when is_integer(ms) do
    Process.send_after(self(), :tick, ms)
  end

  defp run_check(state) do
    start = System.monotonic_time(:microsecond)
    all_healthy = Enum.all?(state.watched, &check_process(&1, state.thresholds))
    duration_us = System.monotonic_time(:microsecond) - start

    :telemetry.execute(
      [:kerf, :monitor, :health_check],
      %{duration_us: duration_us},
      %{process_count: length(state.watched), all_healthy: all_healthy}
    )
  end

  defp check_process(name, thresholds) do
    case Process.whereis(name) do
      nil ->
        :telemetry.execute([:kerf, :monitor, :process_down], %{}, %{name: name})
        false

      pid ->
        check_pid_health(pid, name, thresholds)
    end
  end

  defp check_pid_health(pid, name, thresholds) do
    case Process.info(pid, [:message_queue_len, :memory]) do
      nil ->
        :telemetry.execute([:kerf, :monitor, :process_down], %{}, %{name: name})
        false

      info ->
        queue_len = Keyword.get(info, :message_queue_len, 0)
        memory_bytes = Keyword.get(info, :memory, 0)
        memory_mb = memory_bytes / (1024 * 1024)

        healthy = true

        healthy =
          if queue_len > thresholds.queue_high do
            :telemetry.execute(
              [:kerf, :monitor, :queue_high],
              %{queue_len: queue_len},
              %{name: name, threshold: thresholds.queue_high}
            )

            false
          else
            healthy
          end

        healthy =
          if memory_mb > thresholds.memory_high_mb do
            :telemetry.execute(
              [:kerf, :monitor, :memory_high],
              %{memory_mb: memory_mb},
              %{name: name, threshold: thresholds.memory_high_mb}
            )

            false
          else
            healthy
          end

        healthy
    end
  end

  defp build_status(state) do
    Map.new(state.watched, fn name ->
      case Process.whereis(name) do
        nil ->
          {name, :down}

        pid ->
          case Process.info(pid, [:message_queue_len, :memory]) do
            nil ->
              {name, :down}

            info ->
              queue_len = Keyword.get(info, :message_queue_len, 0)
              memory_mb = Keyword.get(info, :memory, 0) / (1024 * 1024)

              cond do
                queue_len > state.thresholds.queue_high ->
                  {name, {:degraded, "queue_high: #{queue_len}"}}

                memory_mb > state.thresholds.memory_high_mb ->
                  {name, {:degraded, "memory_high: #{Float.round(memory_mb, 1)}MB"}}

                true ->
                  {name, :ok}
              end
          end
      end
    end)
  end
end
