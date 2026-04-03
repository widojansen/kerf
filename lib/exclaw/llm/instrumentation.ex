defmodule ExClaw.LLM.Instrumentation do
  @moduledoc """
  Shared telemetry emission for LLM provider calls.

  Emits standard `:telemetry` events that `Monitor.TelemetryHandlers`
  persists to the `telemetry_events` table.
  """

  @doc "Emit a successful LLM call event."
  def emit_call_stop(provider, model, duration_ms, response) do
    usage = Map.get(response, :usage, %{})

    :telemetry.execute(
      [:exclaw, :llm, :call, :stop],
      %{
        duration_ms: duration_ms,
        tokens_in: Map.get(usage, :input_tokens, 0) || 0,
        tokens_out: Map.get(usage, :output_tokens, 0) || 0
      },
      %{
        model: model,
        provider: provider,
        status: :ok
      }
    )
  rescue
    _ -> :ok
  end

  @doc "Emit an LLM call error event."
  def emit_call_error(provider, model, duration_ms, reason) do
    :telemetry.execute(
      [:exclaw, :llm, :call, :stop],
      %{duration_ms: duration_ms},
      %{
        model: model,
        provider: provider,
        status: :error,
        error: to_string(reason)
      }
    )
  rescue
    _ -> :ok
  end
end
