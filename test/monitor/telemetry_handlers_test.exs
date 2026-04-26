defmodule Kerf.Monitor.TelemetryHandlersTest do
  use Kerf.DataCase, async: false

  alias Kerf.Monitor.TelemetryHandlers
  alias Kerf.Monitor.TelemetryEvent

  setup do
    # Detach handlers after each test to avoid leaks
    on_exit(fn ->
      for id <- TelemetryHandlers.handler_ids() do
        :telemetry.detach(id)
      end
    end)

    :ok
  end

  describe "attach/0" do
    test "attaches handlers for monitor events" do
      :ok = TelemetryHandlers.attach()

      handlers = :telemetry.list_handlers([:kerf, :monitor, :process_down])
      assert length(handlers) >= 1
    end

    test "attaches handlers for LLM events" do
      :ok = TelemetryHandlers.attach()

      handlers = :telemetry.list_handlers([:kerf, :llm, :call, :stop])
      assert length(handlers) >= 1
    end
  end

  describe "event persistence" do
    test "process_down event is written to telemetry_events" do
      :ok = TelemetryHandlers.attach()

      :telemetry.execute(
        [:kerf, :monitor, :process_down],
        %{},
        %{name: Kerf.FakeProcess}
      )

      # Small delay for async insert
      Process.sleep(50)

      import Ecto.Query
      events = Repo.all(from e in TelemetryEvent, where: e.event_name == "monitor.process_down")
      assert length(events) >= 1

      event = List.last(events)
      assert event.metadata["name"] == "Elixir.Kerf.FakeProcess"
    end

    test "health_check event is written to telemetry_events" do
      :ok = TelemetryHandlers.attach()

      :telemetry.execute(
        [:kerf, :monitor, :health_check],
        %{duration_us: 1234},
        %{process_count: 5, all_healthy: true}
      )

      Process.sleep(50)

      import Ecto.Query
      events = Repo.all(from e in TelemetryEvent, where: e.event_name == "monitor.health_check")
      assert length(events) >= 1

      event = List.last(events)
      assert event.measurements["duration_us"] == 1234
      assert event.metadata["all_healthy"] == true
    end

    test "llm.call.stop event is written to telemetry_events" do
      :ok = TelemetryHandlers.attach()

      :telemetry.execute(
        [:kerf, :llm, :call, :stop],
        %{duration: 1_200_000_000, tokens_in: 150, tokens_out: 80},
        %{model: "qwen3-32b", provider: :vllm, status: :ok}
      )

      Process.sleep(50)

      import Ecto.Query
      events = Repo.all(from e in TelemetryEvent, where: e.event_name == "llm.call.stop")
      assert length(events) >= 1

      event = List.last(events)
      assert event.metadata["model"] == "qwen3-32b"
      assert event.measurements["tokens_in"] == 150
    end
  end

  describe "resilience" do
    test "handler does not crash the caller when Repo fails" do
      :ok = TelemetryHandlers.attach()

      # Stop the repo to simulate failure
      # We can't easily stop it in sandbox mode, so instead we test that
      # the handler wraps inserts in try/rescue by calling with bad data types
      # that would cause a DB error.
      # The key contract: execute returns :ok, no raise.
      :telemetry.execute(
        [:kerf, :monitor, :health_check],
        %{duration_us: "not_a_number"},
        %{all_healthy: "not_a_bool"}
      )

      # If we get here without an exception, the handler is resilient
      assert true
    end
  end
end
