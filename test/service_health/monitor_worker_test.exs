defmodule Kerf.ServiceHealth.MonitorWorkerTest do
  # Section A of SPEC_03_MONITOR_WORKER.md — the scheduled, LOG-ONLY worker.
  # Uses the Ecto sandbox (Repo-backed state) + Oban.Testing (perform_job/2).
  use Kerf.DataCase, async: false
  use Oban.Testing, repo: Kerf.Repo

  import ExUnit.CaptureLog

  alias Kerf.ServiceHealth.{MonitorWorker, State}
  alias Kerf.ServiceHealth.Context

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

  # Update the migration-seeded izi2connect row to a known prior state.
  defp set_state!(attrs) do
    State
    |> Repo.get_by!(target: "izi2connect")
    |> State.changeset(attrs)
    |> Repo.update!()
  end

  defp load_state, do: Repo.get_by!(State, target: "izi2connect")

  # Configure the worker's DI seams; telegram_fn records calls (must stay zero).
  defp put_worker_config(overrides) do
    test_pid = self()
    original = Application.get_env(:kerf, MonitorWorker)

    base = [
      fetch_fn: fn -> {:ok, ctx(%{})} end,
      llm_fn: fn _model, _messages, _opts ->
        {:ok, %{type: :text, content: "A composed summary long enough."}}
      end,
      telegram_fn: fn _message, _opts ->
        send(test_pid, :telegram_called)
        {:ok, %{}}
      end,
      now: @now
    ]

    Application.put_env(:kerf, MonitorWorker, Keyword.merge(base, overrides))

    on_exit(fn ->
      if original do
        Application.put_env(:kerf, MonitorWorker, original)
      else
        Application.delete_env(:kerf, MonitorWorker)
      end
    end)
  end

  describe "perform/1 — success / no alert" do
    test "1. healthy poll, no prior alert -> no alert logged, consecutive_healthy incremented, :ok" do
      set_state!(%{last_alert_status: "healthy", consecutive_healthy: 0, consecutive_failures: 0})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "healthy"})} end)

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      refute log =~ "payload="
      state = load_state()
      assert state.consecutive_healthy == 1
      assert state.consecutive_failures == 0
    end
  end

  describe "perform/1 — alert branches (log-only, no Telegram)" do
    test "2. critical -> payload logged + state persisted; TelegramClient NOT called" do
      set_state!(%{last_alert_status: "healthy", consecutive_healthy: 3})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "critical"})} end)

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert log =~ "[monitoring]"
      assert log =~ "payload="
      assert log =~ "🔴"

      state = load_state()
      assert state.last_alert_status == "critical"
      assert state.last_alert_time == @now

      # Log-only proof: the injected Telegram stub saw zero calls.
      refute_received :telegram_called
    end

    test "3. warning + anomalous -> :anomaly payload logged with the warning emoji" do
      set_state!(%{last_alert_status: "healthy"})

      put_worker_config(
        fetch_fn: fn ->
          {:ok, ctx(%{"status" => "warning", "is_anomalous" => true, "anomalies" => [%{"message" => "x"}]})}
        end
      )

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert log =~ "reason=anomaly"
      assert log =~ "⚠️"
      assert load_state().last_alert_status == "anomaly"
    end

    test "4. recovered transition -> recovered payload logged; summary fixed string, LLM NOT called" do
      test_pid = self()
      set_state!(%{last_alert_status: "critical"})

      put_worker_config(
        fetch_fn: fn -> {:ok, ctx(%{"status" => "healthy"})} end,
        llm_fn: fn _m, _msg, _o ->
          send(test_pid, :llm_called)
          {:ok, %{type: :text, content: "unused"}}
        end
      )

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert log =~ "reason=recovered"
      assert log =~ "✅"
      assert log =~ "izi2connect recovered. All systems healthy."
      refute_received :llm_called
      assert load_state().last_alert_status == "recovered"
    end
  end

  describe "perform/1 — fetch failure / unreachable" do
    test "5. fetch error below threshold -> failure counted, no unreachable payload, state persisted" do
      set_state!(%{consecutive_failures: 1})
      put_worker_config(fetch_fn: fn -> {:error, :timeout} end)

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      refute log =~ "🚨"
      refute log =~ "payload="
      assert load_state().consecutive_failures == 2
    end

    test "6. fetch error bringing failures to 3 -> unreachable payload logged with 🚨, last_alert_time set; Telegram NOT called" do
      set_state!(%{consecutive_failures: 2, last_alert_time: nil})
      put_worker_config(fetch_fn: fn -> {:error, :timeout} end)

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert log =~ "🚨"
      assert log =~ "reason=unreachable"

      state = load_state()
      assert state.consecutive_failures == 3
      assert state.last_alert_time == @now

      refute_received :telegram_called
    end
  end

  describe "perform/1 — logging + idempotency" do
    test "7. alert payload is logged under the monitoring metadata tag" do
      set_state!(%{last_alert_status: "healthy"})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "critical"})} end)

      log = capture_log([metadata: [:monitoring]], fn -> perform_job(MonitorWorker, %{}) end)

      # Stable [monitoring] tag + the composed payload string (Spec-4 greps these).
      assert log =~ "[monitoring]"
      assert log =~ "payload="
    end

    test "8. re-running perform on the same input increments by exactly one per poll (max_attempts: 1, no retry double-count)" do
      set_state!(%{last_alert_status: "healthy", consecutive_healthy: 0})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "healthy"})} end)

      capture_log(fn ->
        assert :ok = perform_job(MonitorWorker, %{})
        assert :ok = perform_job(MonitorWorker, %{})
      end)

      # Two distinct polls -> +2. max_attempts: 1 means Oban never auto-retries a
      # single poll, so there is no within-job double-increment.
      assert load_state().consecutive_healthy == 2
    end
  end
end
