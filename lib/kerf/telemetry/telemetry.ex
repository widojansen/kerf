defmodule Kerf.Telemetry do
  @moduledoc """
  Public API for telemetry event emission.

  All functions are fire-and-forget — they never raise, never block the caller,
  and always return `:ok`. If the Logger GenServer is down, events are silently
  discarded.
  """

  alias Kerf.Telemetry.Logger

  @doc """
  Emit a telemetry event (non-blocking cast).
  Returns :ok always, even if the logger is dead.
  """
  def emit(name \\ Logger, category, data) when is_atom(category) and is_map(data) do
    try do
      Logger.emit_event(name, category, data)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Emit a telemetry event synchronously (for deterministic test assertions).
  Returns :ok always, even if the logger is dead.
  """
  def emit_sync(name, category, data) when is_atom(category) and is_map(data) do
    try do
      Logger.emit_event(name, category, data)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Wrap a function call with timing and memory measurement.
  Emits an event with `duration_ms` and `process_memory_bytes`.
  Returns the function's result. If the function raises, the exception
  propagates but the error event is still emitted.
  """
  def span(name \\ Logger, category, data, fun) when is_atom(category) and is_map(data) and is_function(fun, 0) do
    mem_before = process_memory()
    start = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      duration_ms = System.monotonic_time(:millisecond) - start
      mem_after = process_memory()

      emit(name, category, Map.merge(data, %{
        duration_ms: duration_ms,
        process_memory_bytes: mem_after,
        memory_delta_bytes: mem_after - mem_before
      }))

      result
    rescue
      e ->
        duration_ms = System.monotonic_time(:millisecond) - start
        mem_after = process_memory()

        emit(name, category, Map.merge(data, %{
          duration_ms: duration_ms,
          process_memory_bytes: mem_after,
          memory_delta_bytes: mem_after - mem_before,
          error_type: inspect(e.__struct__),
          error_message: Exception.message(e)
        }))

        reraise e, __STACKTRACE__
    end
  end

  defp process_memory do
    {:memory, bytes} = Process.info(self(), :memory)
    bytes
  end
end
