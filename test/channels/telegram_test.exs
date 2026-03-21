defmodule ExClaw.Channels.TelegramTest do
  use ExUnit.Case, async: true

  alias ExClaw.Channels.Telegram

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
          "text" => "Hello ExClaw"
        }
      }

      assert {:ok, msg} = Telegram.extract_message(update)
      assert msg.text == "Hello ExClaw"
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
end
