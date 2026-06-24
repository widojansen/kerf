defmodule Kerf.ServiceHealth.SummaryBuilderTest do
  # Section B of SPEC_03_MONITOR_WORKER.md — pure summary building. No sandbox.
  use ExUnit.Case, async: true

  alias Kerf.ServiceHealth.SummaryBuilder
  alias Kerf.ServiceHealth.Context

  # Synthetic Context — NO real tenant payloads.
  defp full_ctx(attrs \\ %{}) do
    Context.from_map(
      Map.merge(
        %{
          "status" => "critical",
          "is_anomalous" => true,
          "anomalies" => [%{"message" => "queue X at ceiling"}],
          "alerts" => [%{"message" => "elevated error rate"}],
          "current" => %{
            "queues" => %{"total" => 12, "high_wait" => 3, "at_ceiling" => 2},
            "request_rps" => 42.5,
            "service_error_rate" => 1.3
          },
          "baseline" => %{"services" => %{"averages" => %{"error_rate" => 0.8}}}
        },
        attrs
      )
    )
  end

  # Injected llm_fn (model, messages, opts) that records the call and returns `response`.
  defp recording_llm(test_pid, response) do
    fn model, messages, opts ->
      send(test_pid, {:llm_called, model, messages, opts})
      response
    end
  end

  describe "build/2 — recovered (no LLM)" do
    test "9. reason :recovered returns the fixed recovery string; LLM not called" do
      llm = recording_llm(self(), {:ok, %{type: :text, content: "should not be used"}})

      result = SummaryBuilder.build(full_ctx(%{"status" => "healthy"}), :recovered, llm_fn: llm)

      assert result == "izi2connect recovered. All systems healthy."
      refute_received {:llm_called, _, _, _}
    end
  end

  describe "build/2 — LLM prompt" do
    test "10. reason :critical calls the LLM once; prompt carries the key numbers" do
      llm = recording_llm(self(), {:ok, %{type: :text, content: "A sufficiently long summary."}})

      _ = SummaryBuilder.build(full_ctx(), :critical, llm_fn: llm)

      assert_received {:llm_called, _model, messages, _opts}
      prompt = messages |> List.last() |> Map.get(:content)

      assert prompt =~ "critical"
      assert prompt =~ "12"
      assert prompt =~ "1.3"
      assert prompt =~ "0.8"
      refute_received {:llm_called, _, _, _}
    end

    test "11. prompt does NOT contain the Qwen /no_think token" do
      llm = recording_llm(self(), {:ok, %{type: :text, content: "A sufficiently long summary."}})

      _ = SummaryBuilder.build(full_ctx(), :critical, llm_fn: llm)

      assert_received {:llm_called, _model, messages, _opts}
      prompt = messages |> List.last() |> Map.get(:content)
      refute prompt =~ "/no_think"
    end
  end

  describe "build/2 — </think> handling (Nemotron step3 closer-only)" do
    test "12. leading </think> -> content AFTER it is used" do
      llm =
        recording_llm(
          self(),
          {:ok, %{type: :text, content: "internal reasoning here</think>The actual summary is long enough."}}
        )

      result = SummaryBuilder.build(full_ctx(), :critical, llm_fn: llm)

      assert result == "The actual summary is long enough."
    end

    test "13. no </think> -> response used as-is" do
      llm =
        recording_llm(self(), {:ok, %{type: :text, content: "A plain summary with no marker."}})

      result = SummaryBuilder.build(full_ctx(), :critical, llm_fn: llm)

      assert result == "A plain summary with no marker."
    end
  end

  describe "build/2 — fallback triggers" do
    test "14. LLM returns {:error, _} -> fallback assembled from alerts/anomalies" do
      llm = recording_llm(self(), {:error, :boom})

      result = SummaryBuilder.build(full_ctx(), :critical, llm_fn: llm)

      assert result =~ "Alerts: elevated error rate"
      assert result =~ "Anomalies: queue X at ceiling"
    end

    test "15. LLM returns an unusably short response (<= 10 chars) -> fallback" do
      llm = recording_llm(self(), {:ok, %{type: :text, content: "short"}})

      result = SummaryBuilder.build(full_ctx(), :critical, llm_fn: llm)

      assert result =~ "Alerts: elevated error rate"
    end
  end

  describe "fallback/1" do
    test "16. empty alerts and anomalies -> Status-only line" do
      ctx = full_ctx(%{"status" => "warning", "alerts" => [], "anomalies" => []})

      assert SummaryBuilder.fallback(ctx) == "Status: warning"
    end
  end
end
