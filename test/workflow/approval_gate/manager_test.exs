defmodule Kerf.Workflow.ApprovalGate.ManagerTest do
  use Kerf.DataCase, async: false

  alias Kerf.Workflow.ApprovalGate.Manager

  setup do
    opts = [
      name: nil,
      telegram_client: fn _method, _url, _body ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 42}}}}
      end,
      telegram_token: "test_token",
      default_chat_id: 12345
    ]

    {:ok, manager} = Manager.start_link(opts)
    allow_repo(manager)
    %{manager: manager}
  end

  describe "request_approval/2 and resolve/4" do
    test "blocks caller and returns on resolve", %{manager: manager} do
      # Spawn a task to request approval (will block)
      task =
        Task.async(fn ->
          Manager.request_approval(manager, %{
            agent: TestAgent,
            action: "test_action",
            description: "Do the thing?",
            context: %{},
            options: ["Approve", "Reject"],
            timeout_ms: 5_000,
            chat_id: 12345
          })
        end)

      # Give time for the request to be registered
      Process.sleep(50)

      # Should have one pending request
      [pending] = Manager.pending(manager)
      assert pending.action == "test_action"

      # Resolve it
      :ok = Manager.resolve(manager, pending.request_id, "Approve", :human)

      # The blocked task should now return
      result = Task.await(task, 2_000)
      assert {:approved, metadata} = result
      assert metadata.decided_by == :human
      assert metadata.decision == "Approve"
    end

    test "resolve with Reject returns {:rejected, metadata}", %{manager: manager} do
      task =
        Task.async(fn ->
          Manager.request_approval(manager, %{
            agent: TestAgent,
            action: "reject_test",
            description: "Reject me",
            context: %{},
            options: ["Approve", "Reject"],
            timeout_ms: 5_000,
            chat_id: 12345
          })
        end)

      Process.sleep(50)
      [pending] = Manager.pending(manager)
      :ok = Manager.resolve(manager, pending.request_id, "Reject", :human)

      result = Task.await(task, 2_000)
      assert {:rejected, metadata} = result
      assert metadata.decision == "Reject"
    end

    test "resolve with unknown request_id returns error", %{manager: manager} do
      assert {:error, :not_found} = Manager.resolve(manager, "bogus_id", "Approve", :human)
    end
  end

  describe "timeout" do
    test "returns {:error, :timeout} after timeout_ms", %{manager: manager} do
      result =
        Manager.request_approval(manager, %{
          agent: TestAgent,
          action: "timeout_test",
          description: "Will timeout",
          context: %{},
          options: ["Approve", "Reject"],
          timeout_ms: 100,
          chat_id: 12345
        })

      assert {:error, :timeout} = result
    end

    test "cleans up pending request after timeout", %{manager: manager} do
      _result =
        Manager.request_approval(manager, %{
          agent: TestAgent,
          action: "cleanup_test",
          description: "Will timeout",
          context: %{},
          options: ["Approve", "Reject"],
          timeout_ms: 100,
          chat_id: 12345
        })

      assert [] = Manager.pending(manager)
    end
  end

  describe "agent process crash cleanup" do
    test "cleans up pending request when agent process dies", %{manager: manager} do
      # Start a process that will request approval then die
      {pid, ref} =
        spawn_monitor(fn ->
          Manager.request_approval(manager, %{
            agent: TestAgent,
            action: "crash_test",
            description: "Agent will crash",
            context: %{},
            options: ["Approve", "Reject"],
            timeout_ms: 60_000,
            chat_id: 12345
          })
        end)

      Process.sleep(50)
      assert [_pending] = Manager.pending(manager)

      # Kill the agent process
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Give Manager time to handle the DOWN
      Process.sleep(50)
      assert [] = Manager.pending(manager)
    end
  end

  describe "pending/1" do
    test "lists all pending requests", %{manager: manager} do
      # Start two approval requests
      t1 = Task.async(fn ->
        Manager.request_approval(manager, %{
          agent: TestAgent, action: "action_1", description: "First",
          context: %{}, options: ["Approve", "Reject"], timeout_ms: 5_000, chat_id: 12345
        })
      end)

      t2 = Task.async(fn ->
        Manager.request_approval(manager, %{
          agent: TestAgent, action: "action_2", description: "Second",
          context: %{}, options: ["Approve", "Reject"], timeout_ms: 5_000, chat_id: 12345
        })
      end)

      Process.sleep(50)
      pending = Manager.pending(manager)
      assert length(pending) == 2

      # Cleanup
      for p <- pending, do: Manager.resolve(manager, p.request_id, "Approve", :human)
      Task.await(t1, 2_000)
      Task.await(t2, 2_000)
    end
  end

  describe "kill_switch/2" do
    test "rejects all pending requests", %{manager: manager} do
      t1 = Task.async(fn ->
        Manager.request_approval(manager, %{
          agent: TestAgent, action: "ks_1", description: "First",
          context: %{}, options: ["Approve", "Reject"], timeout_ms: 60_000, chat_id: 12345
        })
      end)

      t2 = Task.async(fn ->
        Manager.request_approval(manager, %{
          agent: TestAgent, action: "ks_2", description: "Second",
          context: %{}, options: ["Approve", "Reject"], timeout_ms: 60_000, chat_id: 12345
        })
      end)

      Process.sleep(50)
      assert length(Manager.pending(manager)) == 2

      :ok = Manager.kill_switch(manager, 500)

      r1 = Task.await(t1, 2_000)
      r2 = Task.await(t2, 2_000)

      assert {:error, :killed} = r1
      assert {:error, :killed} = r2
      assert [] = Manager.pending(manager)
    end

    test "suspends new requests during kill switch", %{manager: manager} do
      :ok = Manager.kill_switch(manager, 1_000)

      result =
        Manager.request_approval(manager, %{
          agent: TestAgent, action: "suspended", description: "Should fail",
          context: %{}, options: ["Approve", "Reject"], timeout_ms: 5_000, chat_id: 12345
        })

      assert {:error, :suspended} = result
    end
  end

  describe "resume/1" do
    test "re-enables requests after kill switch", %{manager: manager} do
      :ok = Manager.kill_switch(manager, 60_000)
      assert {:error, :suspended} = Manager.request_approval(manager, %{
        agent: TestAgent, action: "test", description: "Blocked",
        context: %{}, options: ["Approve", "Reject"], timeout_ms: 100, chat_id: 12345
      })

      :ok = Manager.resume(manager)

      # Now should work (will timeout since nobody resolves)
      result = Manager.request_approval(manager, %{
        agent: TestAgent, action: "test", description: "Should work",
        context: %{}, options: ["Approve", "Reject"], timeout_ms: 100, chat_id: 12345
      })

      assert {:error, :timeout} = result
    end
  end

  describe "revoke/2" do
    test "revokes a specific pending request", %{manager: manager} do
      task = Task.async(fn ->
        Manager.request_approval(manager, %{
          agent: TestAgent, action: "revoke_test", description: "Will be revoked",
          context: %{}, options: ["Approve", "Reject"], timeout_ms: 60_000, chat_id: 12345
        })
      end)

      Process.sleep(50)
      [pending] = Manager.pending(manager)

      :ok = Manager.revoke(manager, pending.request_id)

      result = Task.await(task, 2_000)
      assert {:error, :revoked} = result
      assert [] = Manager.pending(manager)
    end

    test "revoke unknown request_id returns error", %{manager: manager} do
      assert {:error, :not_found} = Manager.revoke(manager, "bogus")
    end
  end

  describe "auto-approval" do
    test "auto-approves when rule matches", %{manager: manager} do
      # Create an auto-approval rule
      {:ok, rule} = Kerf.Workflow.ApprovalGate.AutoRule.create(%{
        agent_module: "Elixir.AutoTestAgent",
        action: "auto_action",
        context_pattern: %{},
        decision: "approve"
      })

      result =
        Manager.request_approval(manager, %{
          agent: AutoTestAgent,
          action: "auto_action",
          description: "Should auto-approve",
          context: %{some: "data"},
          options: ["Approve", "Reject"],
          timeout_ms: 5_000,
          chat_id: 12345
        })

      assert {:approved, metadata} = result
      assert metadata.decided_by == :auto_rule
      assert metadata.rule_id == rule.id
    end
  end
end
