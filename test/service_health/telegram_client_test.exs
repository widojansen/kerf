defmodule Kerf.ServiceHealth.TelegramClientTest do
  # Section C of SPEC_03_MONITOR_WORKER.md — Telegram sendMessage client.
  # async: false — mutates Application config for the chat_id.
  use ExUnit.Case, async: false

  alias Kerf.ServiceHealth.TelegramClient

  @vault_key "izimotive/izi2connect_telegram_token"

  setup do
    original = Application.get_env(:kerf, TelegramClient)
    # Fake chat id — NO real tenant chat.
    Application.put_env(:kerf, TelegramClient, chat_id: "fake-chat-999")

    on_exit(fn ->
      if original do
        Application.put_env(:kerf, TelegramClient, original)
      else
        Application.delete_env(:kerf, TelegramClient)
      end
    end)

    :ok
  end

  # HTTP stub (mirrors Spec-1 Client's 5-arity :http_client seam).
  defp recording_http(test_pid, result) do
    fn method, url, body, headers, opts ->
      send(test_pid, {:http, method, url, body, headers, opts})
      result
    end
  end

  # Vault stub — fake token, NO real secret.
  defp recording_vault(test_pid, result \\ {:ok, "fake-token-123"}) do
    fn name ->
      send(test_pid, {:vault, name})
      result
    end
  end

  defp ok_telegram_body, do: %{"ok" => true, "result" => %{"message_id" => 1}}

  describe "send_message/2" do
    test "17. success posts to sendMessage with the config chat id and the text" do
      http = recording_http(self(), {:ok, %{status: 200, body: ok_telegram_body()}})

      assert {:ok, _} =
               TelegramClient.send_message("hello world",
                 http_client: http,
                 vault_fetch: recording_vault(self())
               )

      assert_received {:http, :post, url, body, _headers, _opts}
      assert url =~ "/sendMessage"
      decoded = Jason.decode!(body)
      assert decoded["chat_id"] == "fake-chat-999"
      assert decoded["text"] == "hello world"
    end

    test "18. token is read from the izi2connect vault key" do
      http = recording_http(self(), {:ok, %{status: 200, body: ok_telegram_body()}})

      assert {:ok, _} =
               TelegramClient.send_message("hi",
                 http_client: http,
                 vault_fetch: recording_vault(self())
               )

      assert_received {:vault, @vault_key}
    end

    test "19. Telegram API error (ok: false) -> {:error, _}, no raise" do
      http = recording_http(self(), {:ok, %{status: 200, body: %{"ok" => false, "description" => "bad request"}}})

      assert {:error, _} =
               TelegramClient.send_message("hi",
                 http_client: http,
                 vault_fetch: recording_vault(self())
               )
    end

    test "20. transport failure -> {:error, _}, no raise" do
      http = recording_http(self(), {:error, :timeout})

      assert {:error, _} =
               TelegramClient.send_message("hi",
                 http_client: http,
                 vault_fetch: recording_vault(self())
               )
    end

    test "21. chat id comes from config, not a hardcoded attribute" do
      Application.put_env(:kerf, TelegramClient, chat_id: "override-chat-777")
      http = recording_http(self(), {:ok, %{status: 200, body: ok_telegram_body()}})

      assert {:ok, _} =
               TelegramClient.send_message("hi",
                 http_client: http,
                 vault_fetch: recording_vault(self())
               )

      assert_received {:http, :post, _url, body, _headers, _opts}
      assert Jason.decode!(body)["chat_id"] == "override-chat-777"
    end
  end
end
