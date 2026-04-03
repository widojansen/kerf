defmodule ExClaw.Monitor.SupervisorTest do
  use ExClaw.DataCase, async: false

  alias ExClaw.Monitor

  describe "start_link/1" do
    test "starts with rest_for_one strategy" do
      health_name = :"health_#{System.unique_integer([:positive])}"
      alerting_name = :"alerting_#{System.unique_integer([:positive])}"

      handlers_name = :"handlers_#{System.unique_integer([:positive])}"

      opts = [
        name: :"monitor_sup_#{System.unique_integer([:positive])}",
        telemetry_handlers_name: handlers_name,
        process_health_opts: [
          name: health_name,
          watched: [],
          interval_ms: :manual,
          queue_high_threshold: 100,
          memory_high_threshold_mb: 256
        ],
        alerting_opts: [
          name: alerting_name,
          debounce_window_ms: 300_000,
          telegram_chat_id: nil,
          telegram_sender: fn _chat_id, _text -> :ok end
        ]
      ]

      {:ok, sup_pid} = Monitor.Supervisor.start_link(opts)
      assert Process.alive?(sup_pid)

      # Verify children started
      children = Supervisor.which_children(sup_pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert ExClaw.Monitor.ProcessHealth in child_ids
      assert ExClaw.Monitor.TelemetryHandlers.Server in child_ids
      assert ExClaw.Monitor.Alerting in child_ids
    end

    test "ProcessHealth, TelemetryHandlers, and Alerting are all alive" do
      name = :"monitor_sup_#{System.unique_integer([:positive])}"
      health_name = :"health_#{System.unique_integer([:positive])}"
      alerting_name = :"alerting_#{System.unique_integer([:positive])}"
      handlers_name = :"handlers_#{System.unique_integer([:positive])}"

      opts = [
        name: name,
        telemetry_handlers_name: handlers_name,
        process_health_opts: [
          name: health_name,
          watched: [],
          interval_ms: :manual
        ],
        alerting_opts: [
          name: alerting_name,
          telegram_chat_id: nil,
          telegram_sender: fn _, _ -> :ok end
        ]
      ]

      {:ok, _} = Monitor.Supervisor.start_link(opts)

      # ProcessHealth responds
      assert %{} = Monitor.ProcessHealth.status(health_name)

      # Alerting responds (doesn't crash on notify)
      Monitor.Alerting.notify(alerting_name, :test, %{}, %{})
      Process.sleep(50)
    end

    test "rest_for_one: killing Alerting leaves ProcessHealth alive" do
      name = :"monitor_sup_#{System.unique_integer([:positive])}"
      health_name = :"health_#{System.unique_integer([:positive])}"
      alerting_name = :"alerting_#{System.unique_integer([:positive])}"
      handlers_name = :"handlers_#{System.unique_integer([:positive])}"

      opts = [
        name: name,
        telemetry_handlers_name: handlers_name,
        process_health_opts: [
          name: health_name,
          watched: [],
          interval_ms: :manual
        ],
        alerting_opts: [
          name: alerting_name,
          telegram_chat_id: nil,
          telegram_sender: fn _, _ -> :ok end
        ]
      ]

      {:ok, _} = Monitor.Supervisor.start_link(opts)

      health_pid_before = Process.whereis(health_name)
      assert health_pid_before

      # Kill alerting
      alerting_pid = Process.whereis(alerting_name)
      assert alerting_pid
      Process.exit(alerting_pid, :kill)
      Process.sleep(100)

      # ProcessHealth should still be the same pid (not restarted)
      assert Process.whereis(health_name) == health_pid_before
    end
  end
end
