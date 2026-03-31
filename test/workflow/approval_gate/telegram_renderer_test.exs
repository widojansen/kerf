defmodule ExClaw.Workflow.ApprovalGate.TelegramRendererTest do
  use ExUnit.Case, async: true

  alias ExClaw.Workflow.ApprovalGate.TelegramRenderer

  describe "render_approval_message/1" do
    test "includes agent name, description, and context in text" do
      request = build_request()

      result = TelegramRenderer.render_approval_message(request)

      assert result.chat_id == 12345
      assert result.text =~ "EmailTriage"
      assert result.text =~ "Add john@example.com to priority?"
      assert result.text =~ "sender"
      assert result.text =~ "john@example.com"
    end

    test "renders default Approve/Reject inline keyboard" do
      request = build_request()

      result = TelegramRenderer.render_approval_message(request)

      keyboard = result.reply_markup.inline_keyboard
      assert length(keyboard) == 1
      [row] = keyboard
      assert length(row) == 2

      [approve_btn, reject_btn] = row
      assert approve_btn.text == "Approve"
      assert reject_btn.text == "Reject"
    end

    test "callback_data follows ag:{request_id}:{index} format" do
      request = build_request(%{request_id: "req_abc123"})

      result = TelegramRenderer.render_approval_message(request)

      [row] = result.reply_markup.inline_keyboard
      [approve_btn, reject_btn] = row

      assert approve_btn.callback_data == "ag:req_abc123:0"
      assert reject_btn.callback_data == "ag:req_abc123:1"
    end

    test "callback_data stays within 64-byte Telegram limit" do
      # Use a long request_id that could exceed the limit
      long_id = String.duplicate("x", 50)
      request = build_request(%{request_id: long_id})

      result = TelegramRenderer.render_approval_message(request)

      [row] = result.reply_markup.inline_keyboard
      for btn <- row do
        assert byte_size(btn.callback_data) <= 64
      end
    end

    test "renders custom options beyond Approve/Reject" do
      request = build_request(%{options: ["Send Now", "Delay 1h", "Cancel"]})

      result = TelegramRenderer.render_approval_message(request)

      [row] = result.reply_markup.inline_keyboard
      assert length(row) == 3
      assert Enum.at(row, 0).text == "Send Now"
      assert Enum.at(row, 1).text == "Delay 1h"
      assert Enum.at(row, 2).text == "Cancel"
    end

    test "truncates long descriptions to Telegram's 4096 char limit" do
      long_desc = String.duplicate("a", 5000)
      request = build_request(%{description: long_desc})

      result = TelegramRenderer.render_approval_message(request)

      assert byte_size(result.text) <= 4096
    end

    test "handles empty context" do
      request = build_request(%{context: %{}})

      result = TelegramRenderer.render_approval_message(request)

      assert result.text =~ "Add john@example.com to priority?"
      refute result.text =~ "Context:"
    end

    test "includes parse_mode Markdown" do
      request = build_request()

      result = TelegramRenderer.render_approval_message(request)

      assert result.parse_mode == "HTML"
    end
  end

  describe "render_decision_message/3" do
    test "shows approved by human" do
      request = build_request(%{telegram_message_id: 999})

      result = TelegramRenderer.render_decision_message(request, "Approve", :human)

      assert result.chat_id == 12345
      assert result.message_id == 999
      assert result.text =~ "Approve"
      assert result.text =~ "human"
      # Removes inline keyboard
      assert result.reply_markup == %{inline_keyboard: []}
    end

    test "shows rejected by human" do
      request = build_request(%{telegram_message_id: 999})

      result = TelegramRenderer.render_decision_message(request, "Reject", :human)

      assert result.text =~ "Reject"
    end

    test "shows timed out" do
      request = build_request(%{telegram_message_id: 999})

      result = TelegramRenderer.render_decision_message(request, "timeout", :timeout)

      assert result.text =~ "Timed out"
    end

    test "shows kill switch" do
      request = build_request(%{telegram_message_id: 999})

      result = TelegramRenderer.render_decision_message(request, "reject", :kill_switch)

      assert result.text =~ "Kill switch"
    end

    test "shows auto-approved" do
      request = build_request(%{telegram_message_id: 999})

      result = TelegramRenderer.render_decision_message(request, "Approve", :auto_rule)

      assert result.text =~ "auto-rule"
    end
  end

  describe "render_callback_answer/1" do
    test "builds answerCallbackQuery payload for approve" do
      result = TelegramRenderer.render_callback_answer("cb_query_123", "Approve")

      assert result.callback_query_id == "cb_query_123"
      assert result.text =~ "Approve"
    end

    test "builds answerCallbackQuery payload for reject" do
      result = TelegramRenderer.render_callback_answer("cb_query_456", "Reject")

      assert result.callback_query_id == "cb_query_456"
      assert result.text =~ "Reject"
    end
  end

  describe "parse_callback_data/1" do
    test "parses valid ag: callback data" do
      assert {:ok, "req_123", 0} = TelegramRenderer.parse_callback_data("ag:req_123:0")
      assert {:ok, "req_456", 1} = TelegramRenderer.parse_callback_data("ag:req_456:1")
    end

    test "rejects non-ag prefix" do
      assert :ignore = TelegramRenderer.parse_callback_data("other:data:here")
    end

    test "rejects malformed data" do
      assert :ignore = TelegramRenderer.parse_callback_data("ag:")
      assert :ignore = TelegramRenderer.parse_callback_data("ag:only_one")
      assert :ignore = TelegramRenderer.parse_callback_data("")
    end
  end

  defp build_request(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "req_test_001",
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        description: "Add john@example.com to priority?",
        context: %{sender: "john@example.com", domain: "example.com"},
        options: ["Approve", "Reject"],
        chat_id: 12345,
        telegram_message_id: nil,
        requested_at: ~U[2026-03-31 10:00:00Z],
        timeout_ms: 300_000
      },
      overrides
    )
  end
end
