defmodule Kerf.ServiceHealth.AlertDecisionTest do
  # Section A of SPEC_02_ALERT_STATE_MACHINE.md — pure decision table. No sandbox.
  use ExUnit.Case, async: true

  alias Kerf.ServiceHealth.AlertDecision
  alias Kerf.ServiceHealth.Context

  # Fixed reference clock — tests pin `now` so the throttle boundary is deterministic.
  @now ~U[2026-06-24 12:00:00.000000Z]

  # Synthetic Context — NO real tenant payloads.
  defp ctx(attrs) do
    Context.from_map(
      Map.merge(
        %{"status" => "healthy", "is_anomalous" => false, "anomalies" => [], "alerts" => []},
        attrs
      )
    )
  end

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  describe "Rule 1 — critical" do
    test "1. critical alerts as :critical and ignores state" do
      assert AlertDecision.should_alert(ctx(%{"status" => "critical"}), %{}, @now) ==
               {true, :critical}

      # Rule 1 fires regardless of last_alert_status.
      assert AlertDecision.should_alert(
               ctx(%{"status" => "critical"}),
               %{last_alert_status: :healthy},
               @now
             ) == {true, :critical}
    end
  end

  describe "Rule 2 — warning + anomaly signal" do
    test "2. warning + is_anomalous true (empty anomalies) -> :anomaly" do
      assert AlertDecision.should_alert(
               ctx(%{"status" => "warning", "is_anomalous" => true, "anomalies" => []}),
               %{},
               @now
             ) == {true, :anomaly}
    end

    test "3. warning + is_anomalous false + non-empty anomalies -> :anomaly" do
      assert AlertDecision.should_alert(
               ctx(%{
                 "status" => "warning",
                 "is_anomalous" => false,
                 "anomalies" => [%{"message" => "queue at ceiling"}]
               }),
               %{},
               @now
             ) == {true, :anomaly}
    end
  end

  describe "Rule 3 — warning + alerts, 1800s throttle (strict >)" do
    test "4. warning + alerts, last alert > 1800s ago -> :warning" do
      state = %{last_alert_status: :warning, last_alert_time: ago(1801)}

      assert AlertDecision.should_alert(
               ctx(%{"status" => "warning", "alerts" => [%{"message" => "elevated errors"}]}),
               state,
               @now
             ) == {true, :warning}
    end

    test "5. warning + alerts, last alert < 1800s ago -> throttled, {false, :healthy}" do
      state = %{last_alert_status: :warning, last_alert_time: ago(100)}

      assert AlertDecision.should_alert(
               ctx(%{"status" => "warning", "alerts" => [%{"message" => "elevated errors"}]}),
               state,
               @now
             ) == {false, :healthy}
    end

    test "6. warning + alerts, last alert EXACTLY 1800s ago -> not > 1800, {false, :healthy}" do
      state = %{last_alert_status: :warning, last_alert_time: ago(1800)}

      assert AlertDecision.should_alert(
               ctx(%{"status" => "warning", "alerts" => [%{"message" => "elevated errors"}]}),
               state,
               @now
             ) == {false, :healthy}
    end

    test "9. warning + alerts, last_alert_time nil -> infinitely stale -> :warning" do
      state = %{last_alert_status: nil, last_alert_time: nil}

      assert AlertDecision.should_alert(
               ctx(%{"status" => "warning", "alerts" => [%{"message" => "elevated errors"}]}),
               state,
               @now
             ) == {true, :warning}
    end
  end

  describe "precedence — Rule 2 wins over Rule 3" do
    test "7. warning + anomalous + alerts + stale -> :anomaly (NOT :warning)" do
      state = %{last_alert_status: :warning, last_alert_time: ago(99_999)}

      assert AlertDecision.should_alert(
               ctx(%{
                 "status" => "warning",
                 "is_anomalous" => true,
                 "anomalies" => [%{"message" => "x"}],
                 "alerts" => [%{"message" => "a"}]
               }),
               state,
               @now
             ) == {true, :anomaly}
    end
  end

  describe "warning fall-through" do
    test "8. warning + empty anomalies + empty alerts -> {false, :healthy}" do
      assert AlertDecision.should_alert(
               ctx(%{"status" => "warning", "anomalies" => [], "alerts" => []}),
               %{},
               @now
             ) == {false, :healthy}
    end
  end

  describe "Rule 4 — recovered (keys off last_alert_status)" do
    test "10. healthy + last_alert_status :critical -> :recovered" do
      assert AlertDecision.should_alert(ctx(%{"status" => "healthy"}), %{last_alert_status: :critical}, @now) ==
               {true, :recovered}
    end

    test "11. healthy + last_alert_status :anomaly -> :recovered" do
      assert AlertDecision.should_alert(ctx(%{"status" => "healthy"}), %{last_alert_status: :anomaly}, @now) ==
               {true, :recovered}
    end

    test "12. healthy + last_alert_status :warning -> :recovered" do
      assert AlertDecision.should_alert(ctx(%{"status" => "healthy"}), %{last_alert_status: :warning}, @now) ==
               {true, :recovered}
    end

    test "13. healthy + last_alert_status :recovered -> {false, :healthy} (fires once)" do
      assert AlertDecision.should_alert(ctx(%{"status" => "healthy"}), %{last_alert_status: :recovered}, @now) ==
               {false, :healthy}
    end

    test "14. healthy + last_alert_status :healthy -> {false, :healthy}" do
      assert AlertDecision.should_alert(ctx(%{"status" => "healthy"}), %{last_alert_status: :healthy}, @now) ==
               {false, :healthy}
    end

    test "15. healthy + last_alert_status nil -> {false, :healthy}" do
      assert AlertDecision.should_alert(ctx(%{"status" => "healthy"}), %{last_alert_status: nil}, @now) ==
               {false, :healthy}
    end
  end

  describe "unknown status" do
    test "16. unknown status (\"degraded\") + any state -> {false, :healthy}" do
      # Even with an alerting last_alert_status: unknown status never reaches Rule 4.
      assert AlertDecision.should_alert(
               ctx(%{"status" => "degraded"}),
               %{last_alert_status: :critical},
               @now
             ) == {false, :healthy}
    end
  end
end
