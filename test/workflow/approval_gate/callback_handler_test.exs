defmodule ExClaw.Workflow.ApprovalGate.CallbackHandlerTest do
  use ExClaw.DataCase, async: false

  alias ExClaw.Workflow.ApprovalGate.{CallbackHandler, Manager}

  setup do
    telegram_client = fn _method, _url, _body ->
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 42}}}}
    end

    {:ok, manager} =
      Manager.start_link(
        name: nil,
        telegram_client: telegram_client,
        telegram_token: "test_token",
        default_chat_id: 12345
      )

    allow_repo(manager)

    {:ok, handler} =
      CallbackHandler.start_link(
        name: nil,
        manager: manager,
        telegram_client: telegram_client,
        telegram_token: "test_token"
      )

    %{handler: handler, manager: manager}
  end

  describe "handle_callback/2" do
    test "parses callback_data and resolves the request", %{handler: handler, manager: manager} do
      # Create a pending approval
      task =
        Task.async(fn ->
          Manager.request_approval(manager, %{
            agent: TestAgent,
            action: "cb_test",
            description: "Callback test",
            context: %{},
            options: ["Approve", "Reject"],
            timeout_ms: 5_000,
            chat_id: 12345
          })
        end)

      Process.sleep(50)
      [pending] = Manager.pending(manager)

      # Simulate Telegram callback query
      callback_query = %{
        "id" => "cb_query_001",
        "data" => "ag:#{pending.request_id}:0",
        "from" => %{"id" => 12345, "first_name" => "Test"},
        "message" => %{"message_id" => 42, "chat" => %{"id" => 12345}}
      }

      :ok = CallbackHandler.handle_callback(handler, callback_query)

      result = Task.await(task, 2_000)
      assert {:approved, metadata} = result
      assert metadata.decided_by == :human
      assert metadata.decision == "Approve"
    end

    test "reject button resolves with rejection", %{handler: handler, manager: manager} do
      task =
        Task.async(fn ->
          Manager.request_approval(manager, %{
            agent: TestAgent,
            action: "reject_cb",
            description: "Will reject",
            context: %{},
            options: ["Approve", "Reject"],
            timeout_ms: 5_000,
            chat_id: 12345
          })
        end)

      Process.sleep(50)
      [pending] = Manager.pending(manager)

      callback_query = %{
        "id" => "cb_query_002",
        "data" => "ag:#{pending.request_id}:1",
        "from" => %{"id" => 12345, "first_name" => "Test"},
        "message" => %{"message_id" => 42, "chat" => %{"id" => 12345}}
      }

      :ok = CallbackHandler.handle_callback(handler, callback_query)

      result = Task.await(task, 2_000)
      assert {:rejected, _} = result
    end

    test "ignores callback queries without ag: prefix", %{handler: handler} do
      callback_query = %{
        "id" => "cb_query_003",
        "data" => "other:data:here",
        "from" => %{"id" => 12345},
        "message" => %{"message_id" => 42, "chat" => %{"id" => 12345}}
      }

      assert :ok = CallbackHandler.handle_callback(handler, callback_query)
    end

    test "handles already-resolved request gracefully", %{handler: handler, manager: manager} do
      task =
        Task.async(fn ->
          Manager.request_approval(manager, %{
            agent: TestAgent,
            action: "double_resolve",
            description: "Will be resolved twice",
            context: %{},
            options: ["Approve", "Reject"],
            timeout_ms: 5_000,
            chat_id: 12345
          })
        end)

      Process.sleep(50)
      [pending] = Manager.pending(manager)

      # Resolve via Manager directly
      :ok = Manager.resolve(manager, pending.request_id, "Approve", :human)
      Task.await(task, 2_000)

      # Now try to handle the same callback — should not crash
      callback_query = %{
        "id" => "cb_query_004",
        "data" => "ag:#{pending.request_id}:0",
        "from" => %{"id" => 12345},
        "message" => %{"message_id" => 42, "chat" => %{"id" => 12345}}
      }

      assert :ok = CallbackHandler.handle_callback(handler, callback_query)
    end
  end
end
