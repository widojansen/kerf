defmodule ExClaw.Monitor.AlertingTest do
  use ExUnit.Case, async: true

  alias ExClaw.Monitor.Alerting

  import ExUnit.CaptureLog

  defp start_alerting(opts \\ []) do
    name = :"alerting_#{System.unique_integer([:positive])}"
    test_pid = self()

    # Default: mock telegram sender that reports to test process
    sender =
      Keyword.get(opts, :telegram_sender, fn chat_id, text ->
        send(test_pid, {:telegram_sent, chat_id, text})
        :ok
      end)

    defaults = [
      name: name,
      debounce_window_ms: Keyword.get(opts, :debounce_window_ms, 100),
      telegram_chat_id: Keyword.get(opts, :telegram_chat_id, "12345"),
      telegram_sender: sender
    ]

    {:ok, pid} = Alerting.start_link(defaults)
    {pid, name}
  end

  defp attach_and_fire(name, event, measurements, metadata) do
    # Use Alerting's internal handle — simulate telemetry delivery via cast
    Alerting.notify(name, event, measurements, metadata)
  end

  describe "alert delivery" do
    test "sends Telegram message on :process_down" do
      {_pid, name} = start_alerting()

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})

      assert_receive {:telegram_sent, "12345", text}, 1000
      assert text =~ "ModelRouter"
      assert text =~ "DOWN"
    end

    test "sends Telegram message on :queue_high" do
      {_pid, name} = start_alerting()

      attach_and_fire(name, :queue_high, %{queue_len: 342}, %{
        name: ExClaw.Channels.Telegram,
        threshold: 100
      })

      assert_receive {:telegram_sent, "12345", text}, 1000
      assert text =~ "queue"
      assert text =~ "342"
    end

    test "sends Telegram message on :memory_high" do
      {_pid, name} = start_alerting()

      attach_and_fire(name, :memory_high, %{memory_mb: 512.3}, %{
        name: ExClaw.Agent.Supervisor,
        threshold: 256
      })

      assert_receive {:telegram_sent, "12345", text}, 1000
      assert text =~ "memory"
      assert text =~ "512"
    end
  end

  describe "debounce" do
    test "suppresses duplicate alerts within the debounce window" do
      {_pid, name} = start_alerting(debounce_window_ms: 5_000)

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
      assert_receive {:telegram_sent, _, _}, 1000

      # Fire the same alert again — should be suppressed
      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
      refute_receive {:telegram_sent, _, _}, 200
    end

    test "allows the same alert after debounce window expires" do
      {_pid, name} = start_alerting(debounce_window_ms: 50)

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
      assert_receive {:telegram_sent, _, _}, 1000

      # Wait for debounce to expire
      Process.sleep(80)

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
      assert_receive {:telegram_sent, _, _}, 1000
    end

    test "different alert keys are independent" do
      {_pid, name} = start_alerting(debounce_window_ms: 5_000)

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
      assert_receive {:telegram_sent, _, _}, 1000

      # Different process — should NOT be debounced
      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.Scheduler})
      assert_receive {:telegram_sent, _, _}, 1000
    end
  end

  describe "recovery detection" do
    test "sends recovery message when incident resolves" do
      {_pid, name} = start_alerting()

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
      assert_receive {:telegram_sent, _, _}, 1000

      # Signal recovery
      Alerting.resolve(name, :process_down, %{name: ExClaw.ModelRouter})

      assert_receive {:telegram_sent, "12345", text}, 1000
      assert text =~ "recovered"
      assert text =~ "ModelRouter"
    end

    test "recovery is not sent if there was no active incident" do
      {_pid, name} = start_alerting()

      Alerting.resolve(name, :process_down, %{name: ExClaw.ModelRouter})

      refute_receive {:telegram_sent, _, _}, 200
    end
  end

  describe "fallback" do
    test "logs to Logger.error when Telegram send fails" do
      failing_sender = fn _chat_id, _text -> {:error, "network timeout"} end
      {_pid, name} = start_alerting(telegram_sender: failing_sender)

      log =
        capture_log(fn ->
          attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})
          Process.sleep(100)
        end)

      assert log =~ "Alert delivery failed"
    end
  end

  describe "disabled when no chat_id" do
    test "does not crash when telegram_chat_id is nil" do
      {_pid, name} = start_alerting(telegram_chat_id: nil)

      attach_and_fire(name, :process_down, %{}, %{name: ExClaw.ModelRouter})

      refute_receive {:telegram_sent, _, _}, 200
    end
  end
end
