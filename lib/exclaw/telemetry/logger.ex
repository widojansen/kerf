defmodule Kerf.Telemetry.Logger do
  @moduledoc """
  GenServer that buffers telemetry events and flushes them to ClickHouse
  or a JSONL fallback file.

  Non-blocking: callers use `cast` via `emit_event/3`. The buffer is flushed
  periodically or when it reaches `max_buffer_size`.
  """
  use GenServer

  require Logger

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Non-blocking event emission (cast)."
  def emit_event(name, category, data) when is_atom(category) and is_map(data) do
    GenServer.cast(name, {:emit, category, data})
  end

  @doc "Synchronous flush — blocks until buffer is written. For testing."
  def flush(name) do
    GenServer.call(name, :flush)
  end

  @doc "Current number of buffered events."
  def buffer_size(name) do
    GenServer.call(name, :buffer_size)
  end

  @doc "Returns stats counters."
  def get_stats(name) do
    GenServer.call(name, :get_stats)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, 5_000)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, 100)
    fallback_dir = Keyword.get(opts, :fallback_dir, "priv/telemetry_fallback")
    ch_opts = Keyword.get(opts, :ch_opts)

    ch_pid = connect_clickhouse(ch_opts)

    timer_ref =
      if enabled do
        Process.send_after(self(), :flush, flush_interval_ms)
      else
        nil
      end

    state = %{
      buffer: [],
      buffer_count: 0,
      max_buffer_size: max_buffer_size,
      flush_interval_ms: flush_interval_ms,
      ch_pid: ch_pid,
      ch_opts: ch_opts,
      fallback_dir: fallback_dir,
      enabled: enabled,
      timer_ref: timer_ref,
      stats: %{
        events_received: 0,
        events_flushed: 0,
        flushes: 0,
        ch_writes: 0,
        ch_failures: 0,
        fallback_writes: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:emit, _category, _data}, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:emit, category, data}, state) do
    event = build_event(category, data)

    state = %{
      state
      | buffer: [event | state.buffer],
        buffer_count: state.buffer_count + 1,
        stats: Map.update!(state.stats, :events_received, &(&1 + 1))
    }

    if state.buffer_count >= state.max_buffer_size do
      {:noreply, do_flush(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  def handle_call(:buffer_size, _from, state) do
    {:reply, state.buffer_count, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = Map.put(state.stats, :buffer_size, state.buffer_count)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = do_flush(state)

    timer_ref =
      if state.enabled do
        Process.send_after(self(), :flush, state.flush_interval_ms)
      else
        nil
      end

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp build_event(category, data) do
    data
    |> Map.put(:event_type, Atom.to_string(category))
    |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp do_flush(%{buffer_count: 0} = state) do
    state
  end

  defp do_flush(state) do
    events = Enum.reverse(state.buffer)

    state =
      case write_to_clickhouse(state.ch_pid, events) do
        :ok ->
          update_stats(state, :ch_writes, length(events))

        :error ->
          write_to_fallback(state.fallback_dir, events)
          update_stats(state, :fallback_writes, length(events))
      end

    state = update_stats(state, :flushes, 1)
    state = %{state | stats: Map.update!(state.stats, :events_flushed, &(&1 + length(events)))}

    %{state | buffer: [], buffer_count: 0}
  end

  defp connect_clickhouse(nil), do: nil

  defp connect_clickhouse(opts) do
    try do
      {:ok, pid} = Ch.start_link(opts)
      pid
    rescue
      _ -> nil
    end
  end

  defp write_to_clickhouse(nil, _events), do: :error

  defp write_to_clickhouse(pid, events) do
    try do
      rows =
        Enum.map(events, fn event ->
          [
            event[:timestamp] || DateTime.utc_now() |> DateTime.to_iso8601(),
            event[:event_type] || "",
            event[:group_id] || "",
            event[:session_id] || "",
            event[:latency_ms] || event[:duration_ms] || 0,
            event[:model] || "",
            event[:input_tokens] || 0,
            event[:output_tokens] || 0,
            event[:response_type] || "",
            event[:tool_name] || "",
            event[:security_result] || "",
            event[:input_data] || "",
            event[:output_data] || "",
            event[:error_type] || "",
            event[:error_message] || "",
            event[:channel] || "",
            event[:memory_delta_bytes] || 0,
            event[:process_memory_bytes] || 0,
            event[:metadata] || ""
          ]
        end)

      Ch.query!(pid, """
      INSERT INTO exclaw_events (
        timestamp, event_type, group_id, session_id, latency_ms,
        model, input_tokens, output_tokens, response_type,
        tool_name, security_result, input_data, output_data,
        error_type, error_message, channel,
        memory_delta_bytes, process_memory_bytes, metadata
      ) VALUES
      """, rows)

      :ok
    rescue
      _ -> :error
    end
  end

  defp write_to_fallback(fallback_dir, events) do
    try do
      File.mkdir_p!(fallback_dir)
      date = Date.utc_today() |> Date.to_iso8601()
      path = Path.join(fallback_dir, "events_#{date}.jsonl")

      lines =
        events
        |> Enum.map(fn event ->
          event
          |> stringify_keys()
          |> Jason.encode!()
        end)
        |> Enum.join("\n")

      File.write!(path, lines <> "\n", [:append])
    rescue
      _ -> :ok
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp update_stats(state, key, increment) do
    %{state | stats: Map.update!(state.stats, key, &(&1 + increment))}
  end
end
