defmodule Kerf.Channels.TelegramTest do
  use ExUnit.Case, async: true

  alias Kerf.Channels.Telegram

  describe "derive_group_id/1" do
    test "derives group_id from chat id" do
      update = %{"message" => %{"chat" => %{"id" => 12345}, "text" => "hi"}}
      assert Telegram.derive_group_id(update) == "tg_12345"
    end

    test "handles negative group chat ids" do
      update = %{"message" => %{"chat" => %{"id" => -100_123_456}, "text" => "hi"}}
      assert Telegram.derive_group_id(update) == "tg_-100123456"
    end
  end

  describe "extract_message/1" do
    test "extracts text from message update" do
      update = %{
        "update_id" => 1001,
        "message" => %{
          "message_id" => 42,
          "chat" => %{"id" => 12345},
          "from" => %{"id" => 999, "first_name" => "Alice"},
          "text" => "Hello Kerf"
        }
      }

      assert {:ok, msg} = Telegram.extract_message(update)
      assert msg.text == "Hello Kerf"
      assert msg.chat_id == 12345
      assert msg.from_id == 999
      assert msg.update_id == 1001
    end

    test "returns error for update without message" do
      assert {:skip, _} = Telegram.extract_message(%{"update_id" => 1002})
    end

    test "returns error for message without text" do
      update = %{
        "update_id" => 1003,
        "message" => %{
          "chat" => %{"id" => 12345},
          "from" => %{"id" => 999},
          "photo" => [%{"file_id" => "abc"}]
        }
      }

      assert {:skip, _} = Telegram.extract_message(update)
    end
  end

  describe "authorized?/2" do
    test "allows when allow_from is empty (no restrictions)" do
      assert Telegram.authorized?(999, [])
    end

    test "allows when user_id is in allow_from list" do
      assert Telegram.authorized?(999, [999, 888])
    end

    test "denies when user_id is not in allow_from list" do
      refute Telegram.authorized?(777, [999, 888])
    end
  end

  describe "strip_thinking/1" do
    test "strips <think> tags from response" do
      text = "<think>\nLet me think...\n</think>\n\nThe answer is 4."
      assert Telegram.strip_thinking(text) == "The answer is 4."
    end

    test "returns text unchanged when no think tags" do
      text = "The answer is 4."
      assert Telegram.strip_thinking(text) == "The answer is 4."
    end

    test "handles empty think block" do
      text = "<think>\n\n</think>\n\nfour"
      assert Telegram.strip_thinking(text) == "four"
    end

    test "handles text with only think block" do
      text = "<think>\nthinking...\n</think>"
      assert Telegram.strip_thinking(text) == ""
    end
  end

  describe "build_send_body/2" do
    test "builds sendMessage request body" do
      body = Telegram.build_send_body(12345, "Hello!")
      assert body["chat_id"] == 12345
      assert body["text"] == "Hello!"
    end

    test "truncates long messages" do
      long_text = String.duplicate("a", 5000)
      body = Telegram.build_send_body(12345, long_text)
      assert String.length(body["text"]) <= 4096
    end
  end

  describe "build_system_prompt/2" do
    test "returns base_prompt when no group memory" do
      prompt = Telegram.build_system_prompt("You are Tina.", nil)
      assert prompt == "You are Tina."
    end

    test "returns base_prompt when group memory is empty string" do
      prompt = Telegram.build_system_prompt("You are Tina.", "")
      assert prompt == "You are Tina."
    end

    test "appends group memory to base_prompt" do
      prompt = Telegram.build_system_prompt("You are Tina.", "User prefers Dutch greetings")
      assert prompt =~ "You are Tina."
      assert prompt =~ "Group Memory"
      assert prompt =~ "User prefers Dutch greetings"
    end
  end

  describe "extract_message/1 with callback_query" do
    test "skips callback_query updates (handled separately)" do
      update = %{
        "update_id" => 2001,
        "callback_query" => %{
          "id" => "cb_123",
          "data" => "ag:req_001:0",
          "from" => %{"id" => 999}
        }
      }

      assert {:skip, "not a message update"} = Telegram.extract_message(update)
    end
  end

  describe "is_callback_query?/1" do
    test "returns true for callback_query updates" do
      update = %{
        "update_id" => 2001,
        "callback_query" => %{"id" => "cb_123", "data" => "ag:req:0"}
      }

      assert Telegram.is_callback_query?(update)
    end

    test "returns false for regular message updates" do
      update = %{
        "update_id" => 2001,
        "message" => %{
          "chat" => %{"id" => 12345},
          "from" => %{"id" => 999},
          "text" => "hi"
        }
      }

      refute Telegram.is_callback_query?(update)
    end

    test "returns false for empty update" do
      refute Telegram.is_callback_query?(%{"update_id" => 2001})
    end
  end

  describe "parse_updates_response/1" do
    test "parses successful getUpdates response" do
      body = %{
        "ok" => true,
        "result" => [
          %{
            "update_id" => 1001,
            "message" => %{
              "chat" => %{"id" => 12345},
              "from" => %{"id" => 999},
              "text" => "hi"
            }
          }
        ]
      }

      assert {:ok, updates} = Telegram.parse_updates_response(body)
      assert length(updates) == 1
    end

    test "handles empty result" do
      body = %{"ok" => true, "result" => []}
      assert {:ok, []} = Telegram.parse_updates_response(body)
    end

    test "handles error response" do
      body = %{"ok" => false, "description" => "Unauthorized"}
      assert {:error, _} = Telegram.parse_updates_response(body)
    end
  end

  describe "send_message/3" do
    # Step 12: public sender seam. Token resolved internally via app config;
    # caller passes chat_id, text, and optional :http_client for tests.
    # async: false on this test only would be necessary if Application.put_env
    # races; we mitigate via a per-test unique config target. The file-level
    # async: true is preserved because the test sets and restores its own env
    # key with on_exit, and Application config writes are atomic.

    test "sends a Telegram message and returns :ok on 200" do
      test_pid = self()

      adapter = fn request ->
        body = Jason.decode!(request.body)
        send(test_pid, {:telegram_post, request.url, body})
        {request, Req.Response.new(status: 200, body: %{"ok" => true})}
      end

      previous = Application.get_env(:kerf, Kerf.Channels.Telegram, [])
      Application.put_env(:kerf, Kerf.Channels.Telegram, Keyword.put(previous, :token, "test_bot_abc"))
      on_exit(fn -> Application.put_env(:kerf, Kerf.Channels.Telegram, previous) end)

      assert :ok = Telegram.send_message(12345, "Hello from Step 12", http_client: adapter)

      assert_receive {:telegram_post, url, body}
      assert to_string(url) =~ "/bot/sendMessage" or to_string(url) =~ "test_bot_abc"
      assert body["chat_id"] == 12345
      assert body["text"] == "Hello from Step 12"
    end
  end
end
