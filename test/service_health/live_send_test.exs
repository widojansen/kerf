defmodule Kerf.ServiceHealth.LiveSendTest do
  # Spec 3->4 bridge: the LIVE-SEND GATE. Purely additive, DEFAULT-OFF extension of
  # MonitorWorker + TelegramClient. See docs/specs/SPEC_04_CUTOVER.md.
  #
  # Lives in its own file so the 83 frozen Spec-1/2/3 service_health tests stay
  # byte-unchanged. Uses an arity-1 telegram_fn stub, matching the GREEN design
  # (maybe_send calls a wrapper over TelegramClient.send_message/1 with the payload).
  #
  # async: false — mutates Application config for MonitorWorker / TelegramClient.
  use Kerf.DataCase, async: false
  use Oban.Testing, repo: Kerf.Repo

  import ExUnit.CaptureLog

  alias Kerf.ServiceHealth.{MonitorWorker, TelegramClient, State}
  alias Kerf.ServiceHealth.Context

  @now ~U[2026-06-24 12:00:00.000000Z]
  @unreachable_payload "🚨 izi-monitoring API unreachable for 15+ minutes. Check server."

  defp ctx(attrs) do
    Context.from_map(
      Map.merge(
        %{"status" => "healthy", "is_anomalous" => false, "anomalies" => [], "alerts" => []},
        attrs
      )
    )
  end

  defp set_state!(attrs) do
    State
    |> Repo.get_by!(target: "izi2connect")
    |> State.changeset(attrs)
    |> Repo.update!()
  end

  # Base config; telegram_fn is arity-1 (the live-send wrapper shape) and records
  # the payload it was handed so tests can assert called/not-called + exact payload.
  defp put_worker_config(overrides) do
    test_pid = self()
    original = Application.get_env(:kerf, MonitorWorker)

    base = [
      fetch_fn: fn -> {:ok, ctx(%{"status" => "healthy"})} end,
      llm_fn: fn _m, _msg, _o -> {:ok, %{type: :text, content: "A composed summary long enough."}} end,
      now: @now,
      telegram_fn: fn payload ->
        send(test_pid, {:telegram_sent, payload})
        {:ok, %{}}
      end
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

  defp put_telegram_chat_id(chat_id) do
    original = Application.get_env(:kerf, TelegramClient)
    Application.put_env(:kerf, TelegramClient, chat_id: chat_id)

    on_exit(fn ->
      if original do
        Application.put_env(:kerf, TelegramClient, original)
      else
        Application.delete_env(:kerf, TelegramClient)
      end
    end)
  end

  # ============================ GENUINELY RED ============================
  # (feature absent in the current log-only worker / unguarded client)

  describe "live-send gate — RED (feature absent until GREEN)" do
    test "L1. live_send true + success alert -> telegram_fn called exactly once with the composed payload" do
      set_state!(%{last_alert_status: "healthy"})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "critical"})} end, live_send: true)

      capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert_received {:telegram_sent, payload}
      assert payload == "🔴 A composed summary long enough."
      refute_received {:telegram_sent, _}
    end

    test "L2. live_send true + unreachable -> telegram_fn called once with the unreachable payload" do
      set_state!(%{consecutive_failures: 2, last_alert_time: nil})
      put_worker_config(fetch_fn: fn -> {:error, :timeout} end, live_send: true)

      capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert_received {:telegram_sent, payload}
      assert payload == @unreachable_payload
      refute_received {:telegram_sent, _}
    end

    test "L3. live_send true + telegram_fn {:error,_} -> worker logs the error AND returns :ok" do
      set_state!(%{last_alert_status: "healthy"})

      put_worker_config(
        fetch_fn: fn -> {:ok, ctx(%{"status" => "critical"})} end,
        live_send: true,
        telegram_fn: fn _payload -> {:error, :telegram_down} end
      )

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      # A send failure must not crash the job; it logs and self-heals next tick.
      assert log =~ "send failed"
    end

    test "L4. TelegramClient.send_message with chat_id nil -> {:error, :missing_chat_id}, ZERO http calls" do
      test_pid = self()
      put_telegram_chat_id(nil)

      http = fn _method, _url, _body, _headers, _opts ->
        send(test_pid, :http_called)
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end

      vault = fn _name -> {:ok, "fake-token-123"} end

      assert {:error, :missing_chat_id} =
               TelegramClient.send_message("hi", http_client: http, vault_fetch: vault)

      refute_received :http_called
    end
  end

  # ===================== REGRESSION GUARDS (green throughout) =====================
  # Pass at RED (current behavior already = never send) AND after GREEN. They pin
  # default-off and alert-only-send so a future change can't silently regress them.

  describe "live-send gate — guards (green before and after)" do
    test "L5. live_send false/absent + alert -> telegram_fn NOT called (default-off)" do
      set_state!(%{last_alert_status: "healthy"})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "critical"})} end)

      capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      refute_received {:telegram_sent, _}
    end

    test "L6. live_send true + NO-alert poll -> telegram_fn NOT called (only alerts send)" do
      set_state!(%{last_alert_status: "healthy", consecutive_healthy: 0})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "healthy"})} end, live_send: true)

      capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      refute_received {:telegram_sent, _}
    end

    test "L7. live_send true + alert -> the [monitoring] log line is STILL emitted (send augments, not replaces)" do
      set_state!(%{last_alert_status: "healthy"})
      put_worker_config(fetch_fn: fn -> {:ok, ctx(%{"status" => "critical"})} end, live_send: true)

      log = capture_log(fn -> assert :ok = perform_job(MonitorWorker, %{}) end)

      assert log =~ "[monitoring]"
      assert log =~ "payload="
    end
  end
end
