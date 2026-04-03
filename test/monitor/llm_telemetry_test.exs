defmodule ExClaw.Monitor.LLMTelemetryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Verifies that LLM providers emit [:exclaw, :llm, :call, :stop] and
  [:exclaw, :llm, :call, :exception] telemetry events.

  Uses telemetry handler attachment rather than actually calling the
  providers (which would need HTTP mocks). We test the instrumentation
  helper that all three providers call.
  """

  alias ExClaw.LLM.Instrumentation

  defp attach_handler(event_name) do
    ref = make_ref()
    test_pid = self()
    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach(handler_id, event_name, fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "Instrumentation.emit_call_stop/4" do
    test "emits [:exclaw, :llm, :call, :stop] with model, duration, tokens" do
      attach_handler([:exclaw, :llm, :call, :stop])

      response = %{
        type: :text,
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      Instrumentation.emit_call_stop(:vllm, "qwen3-32b", 1200, response)

      assert_receive {:telemetry, [:exclaw, :llm, :call, :stop],
                       %{duration_ms: 1200, tokens_in: 100, tokens_out: 50},
                       %{model: "qwen3-32b", provider: :vllm, status: :ok}},
                     1000
    end

    test "handles missing usage gracefully" do
      attach_handler([:exclaw, :llm, :call, :stop])

      response = %{type: :text}
      Instrumentation.emit_call_stop(:anthropic, "claude-sonnet", 500, response)

      assert_receive {:telemetry, [:exclaw, :llm, :call, :stop],
                       %{duration_ms: 500, tokens_in: 0, tokens_out: 0},
                       %{model: "claude-sonnet", provider: :anthropic, status: :ok}},
                     1000
    end
  end

  describe "Instrumentation.emit_call_error/4" do
    test "emits [:exclaw, :llm, :call, :stop] with error status" do
      attach_handler([:exclaw, :llm, :call, :stop])

      Instrumentation.emit_call_error(:vllm, "qwen3-32b", 3000, "connection refused")

      assert_receive {:telemetry, [:exclaw, :llm, :call, :stop],
                       %{duration_ms: 3000},
                       %{model: "qwen3-32b", provider: :vllm, status: :error, error: "connection refused"}},
                     1000
    end
  end
end
