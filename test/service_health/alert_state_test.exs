defmodule Kerf.ServiceHealth.AlertStateTest do
  # Section B of SPEC_02_ALERT_STATE_MACHINE.md — pure state mutation. No sandbox.
  use ExUnit.Case, async: true

  alias Kerf.ServiceHealth.AlertState
  alias Kerf.ServiceHealth.AlertDecision
  alias Kerf.ServiceHealth.Context

  @now ~U[2026-06-24 12:00:00.000000Z]

  defp ctx(attrs) do
    Context.from_map(
      Map.merge(
        %{"status" => "healthy", "is_anomalous" => false, "anomalies" => [], "alerts" => []},
        attrs
      )
    )
  end

  # Prior state with Python-default values, overridable per test.
  defp prior(overrides \\ %{}) do
    Map.merge(
      %{
        last_alert_status: :healthy,
        last_alert_time: nil,
        consecutive_healthy: 0,
        consecutive_failures: 0
      },
      overrides
    )
  end

  describe "success path — counters" do
    test "17. successful healthy no-alert poll: consecutive_healthy +1, consecutive_failures -> 0" do
      {next, signals} =
        AlertState.advance(
          prior(%{consecutive_healthy: 5, consecutive_failures: 0}),
          {:ok, ctx(%{"status" => "healthy"})},
          {false, :healthy},
          @now
        )

      assert next.consecutive_healthy == 6
      assert next.consecutive_failures == 0
      assert signals.unreachable_alert == false
    end

    test "18. successful fetch resets a non-zero consecutive_failures to 0" do
      {next, _signals} =
        AlertState.advance(
          prior(%{consecutive_failures: 7}),
          {:ok, ctx(%{"status" => "healthy"})},
          {false, :healthy},
          @now
        )

      assert next.consecutive_failures == 0
    end
  end

  describe "success path — last_alert_status reset on no-alert healthy poll" do
    test "19. no-alert healthy poll with last_alert_status :anomaly -> reset to :healthy" do
      {next, _} =
        AlertState.advance(
          prior(%{last_alert_status: :anomaly}),
          {:ok, ctx(%{"status" => "healthy"})},
          {false, :healthy},
          @now
        )

      assert next.last_alert_status == :healthy
    end

    test "20. no-alert healthy poll with last_alert_status :recovered -> stays :recovered" do
      {next, _} =
        AlertState.advance(
          prior(%{last_alert_status: :recovered}),
          {:ok, ctx(%{"status" => "healthy"})},
          {false, :healthy},
          @now
        )

      assert next.last_alert_status == :recovered
    end

    test "21. no-alert healthy poll with last_alert_status nil -> stays nil" do
      {next, _} =
        AlertState.advance(
          prior(%{last_alert_status: nil}),
          {:ok, ctx(%{"status" => "healthy"})},
          {false, :healthy},
          @now
        )

      assert next.last_alert_status == nil
    end
  end

  describe "success path — alert fires" do
    test "22. alert fires (:critical): last_alert_status -> :critical, last_alert_time -> now" do
      {next, _} =
        AlertState.advance(
          prior(%{last_alert_status: :healthy, last_alert_time: nil}),
          {:ok, ctx(%{"status" => "critical"})},
          {true, :critical},
          @now
        )

      assert next.last_alert_status == :critical
      assert next.last_alert_time == @now
    end
  end

  describe "failure path — consecutive_failures + unreachable signal" do
    test "23. fetch failure increments consecutive_failures, no unreachable signal while < 3" do
      {next, signals} =
        AlertState.advance(prior(%{consecutive_failures: 1}), {:error, :timeout}, nil, @now)

      assert next.consecutive_failures == 2
      assert signals.unreachable_alert == false
    end

    test "24. failure bringing consecutive_failures to exactly 3 -> unreachable true + last_alert_time set" do
      {next, signals} =
        AlertState.advance(prior(%{consecutive_failures: 2}), {:error, :timeout}, nil, @now)

      assert next.consecutive_failures == 3
      assert signals.unreachable_alert == true
      assert next.last_alert_time == @now
    end

    test "25. failure at 4, 5... -> unreachable still true each poll, last_alert_time updated each time" do
      {next4, signals4} =
        AlertState.advance(prior(%{consecutive_failures: 3}), {:error, :timeout}, nil, @now)

      assert next4.consecutive_failures == 4
      assert signals4.unreachable_alert == true
      assert next4.last_alert_time == @now

      {next5, signals5} =
        AlertState.advance(prior(%{consecutive_failures: 4}), {:error, :timeout}, nil, @now)

      assert next5.consecutive_failures == 5
      assert signals5.unreachable_alert == true
      assert next5.last_alert_time == @now
    end

    test "26. asymmetry: unreachable path sets last_alert_time but leaves last_alert_status unchanged" do
      {next, signals} =
        AlertState.advance(
          prior(%{consecutive_failures: 2, last_alert_status: :warning, last_alert_time: nil}),
          {:error, :timeout},
          nil,
          @now
        )

      assert signals.unreachable_alert == true
      assert next.last_alert_time == @now
      # PRESERVED asymmetry: status NOT touched by the unreachable path.
      assert next.last_alert_status == :warning
    end
  end

  describe "consecutive_healthy is never a decision input" do
    test "27. consecutive_healthy 9_999 vs 0 yields identical should_alert result" do
      # 9_999 (not the live 18896 — that value belongs to Spec 4's state.json migration).
      base = %{last_alert_status: :warning, last_alert_time: DateTime.add(@now, -1801, :second)}
      warning_ctx = ctx(%{"status" => "warning", "alerts" => [%{"message" => "elevated errors"}]})

      big = AlertDecision.should_alert(warning_ctx, Map.put(base, :consecutive_healthy, 9_999), @now)
      zero = AlertDecision.should_alert(warning_ctx, Map.put(base, :consecutive_healthy, 0), @now)

      assert big == zero
      assert big == {true, :warning}
    end
  end
end
