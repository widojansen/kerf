defmodule Kerf.ServiceHealth.ContextTest do
  use ExUnit.Case, async: true

  alias Kerf.ServiceHealth.Context
  alias Kerf.ServiceHealth.Context.{Current, Queues, Baseline}

  # Synthetic payload — NO real tenant data, keys, or tokens.
  # Shape matches the confirmed live response described in SPEC_01_HEALTH_CLIENT.md.
  @full_payload %{
    "status" => "anomalous",
    "is_anomalous" => true,
    "anomalies" => [
      %{"type" => "queue_ceiling", "message" => "queue X at ceiling"}
    ],
    "alerts" => [
      %{"severity" => "warning", "message" => "elevated error rate"}
    ],
    "current" => %{
      "queues" => %{
        "total" => 12,
        "healthy" => 9,
        "at_ceiling" => 2,
        "high_wait" => 1
      },
      "request_rps" => 42.5,
      "service_error_rate" => 1.3,
      "web" => %{
        "p95_latency_ms" => 240,
        "endpoints" => [%{"path" => "/api/x", "rps" => 10.0}]
      }
    },
    "baseline" => %{
      "requests" => %{"avg_rps" => 38.0},
      "services" => %{"averages" => %{"error_rate" => 0.8}},
      "jobs" => %{"avg_runtime_ms" => 1200},
      "maximums" => %{"peak_rps" => 88.0}
    }
  }

  describe "from_map/1 — full confirmed payload" do
    test "1. every known field is typed correctly and nested structs are populated" do
      ctx = Context.from_map(@full_payload)

      assert %Context{} = ctx
      assert ctx.status == "anomalous"
      assert ctx.is_anomalous == true
      assert ctx.anomalies == [%{"type" => "queue_ceiling", "message" => "queue X at ceiling"}]
      assert ctx.alerts == [%{"severity" => "warning", "message" => "elevated error rate"}]

      assert %Current{} = ctx.current
      assert %Queues{} = ctx.current.queues
      assert ctx.current.queues.total == 12
      assert ctx.current.queues.healthy == 9
      assert ctx.current.queues.at_ceiling == 2
      assert ctx.current.queues.high_wait == 1
      assert ctx.current.request_rps == 42.5
      assert ctx.current.service_error_rate == 1.3

      assert %Baseline{} = ctx.baseline
      assert ctx.baseline.requests == %{"avg_rps" => 38.0}
      assert ctx.baseline.services == %{"averages" => %{"error_rate" => 0.8}}
      assert ctx.baseline.jobs == %{"avg_runtime_ms" => 1200}
    end
  end

  describe "from_map/1 — lossless preservation of unmodeled fields" do
    test "2. current.web is preserved verbatim in Current.raw" do
      ctx = Context.from_map(@full_payload)

      assert ctx.current.raw["web"] == %{
               "p95_latency_ms" => 240,
               "endpoints" => [%{"path" => "/api/x", "rps" => 10.0}]
             }
    end

    test "3. baseline.maximums is preserved verbatim in Baseline.raw" do
      ctx = Context.from_map(@full_payload)

      assert ctx.baseline.raw["maximums"] == %{"peak_rps" => 88.0}
    end

    test "4. unknown top-level key is preserved in Context.raw" do
      payload = Map.put(@full_payload, "future_field", %{"x" => 1})
      ctx = Context.from_map(payload)

      assert ctx.raw["future_field"] == %{"x" => 1}
    end
  end

  describe "from_map/1 — lenient defaults (graceful degradation)" do
    test "5. missing known field (current.service_error_rate) parses to default, no raise" do
      current = Map.delete(@full_payload["current"], "service_error_rate")
      payload = Map.put(@full_payload, "current", current)

      ctx = Context.from_map(payload)

      assert ctx.current.service_error_rate == 0
      assert %Current{} = ctx.current
    end

    test "18. missing top-level current/baseline still yield populated default structs" do
      payload = @full_payload |> Map.delete("current") |> Map.delete("baseline")

      ctx = Context.from_map(payload)

      assert %Current{} = ctx.current
      assert %Queues{} = ctx.current.queues
      assert ctx.current.queues.total == 0
      assert ctx.current.request_rps == 0
      assert %Baseline{} = ctx.baseline
      assert ctx.baseline.requests == %{}
    end

    test "19. empty map parses to all documented defaults, no raise" do
      ctx = Context.from_map(%{})

      assert ctx.status == "unknown"
      assert ctx.is_anomalous == false
      assert ctx.anomalies == []
      assert ctx.alerts == []
    end
  end

  describe "from_map/1 — list and flag semantics" do
    test "6. empty anomalies / alerts parse to [], not nil" do
      payload = @full_payload |> Map.put("anomalies", []) |> Map.put("alerts", [])

      ctx = Context.from_map(payload)

      assert ctx.anomalies == []
      assert ctx.alerts == []
      refute is_nil(ctx.anomalies)
      refute is_nil(ctx.alerts)
    end

    test "7. is_anomalous and anomalies are independent and both preserved" do
      payload =
        @full_payload
        |> Map.put("is_anomalous", true)
        |> Map.put("anomalies", [%{"message" => "a"}, %{"message" => "b"}])

      ctx = Context.from_map(payload)

      assert ctx.is_anomalous == true
      assert length(ctx.anomalies) == 2
    end
  end
end
