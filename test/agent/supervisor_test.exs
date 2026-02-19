defmodule ExClaw.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  alias ExClaw.Agent.Supervisor
  alias ExClaw.LLM.{Provider, RateLimiter}

  defp text_response(text) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 25}
    }
  end

  # Start an isolated DynamicSupervisor + Registry + Provider + RateLimiter
  defp start_infra do
    suffix = System.unique_integer([:positive])
    sup_name = :"test_agent_sup_#{suffix}"
    reg_name = :"test_session_reg_#{suffix}"
    rl_name = :"test_rl_sup_#{suffix}"
    provider_name = :"test_provider_sup_#{suffix}"

    {:ok, _} = Registry.start_link(keys: :unique, name: reg_name)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      idx = Agent.get_and_update(counter, fn i -> {i, i + 1} end)
      body = if idx == 0, do: text_response("first"), else: text_response("reply #{idx}")
      {request, Req.Response.json(body)}
    end

    {:ok, _} = RateLimiter.start_link(name: rl_name)

    {:ok, _} =
      Provider.start_link(
        name: provider_name,
        api_key: "test-key",
        adapter: adapter,
        rate_limiter: rl_name
      )

    {:ok, _} = Supervisor.start_link(name: sup_name)

    %{
      sup: sup_name,
      registry: reg_name,
      provider: provider_name,
      rl: rl_name,
      suffix: suffix
    }
  end

  describe "start_session/1" do
    test "starts a session under the DynamicSupervisor" do
      %{sup: sup, provider: provider} = start_infra()

      assert {:ok, pid} =
               Supervisor.start_session(sup,
                 group_id: "test_group",
                 provider: provider,
                 model: "claude-sonnet-4-20250514"
               )

      assert Process.alive?(pid)
    end
  end

  describe "handle_message/3" do
    test "starts new session when none exists and returns response" do
      %{sup: sup, registry: reg, provider: provider} = start_infra()

      assert {:ok, "first"} =
               Supervisor.handle_message(sup, reg, "new_group",
                 "Hello",
                 provider: provider,
                 model: "claude-sonnet-4-20250514"
               )
    end

    test "finds existing session via Registry on second message" do
      %{sup: sup, registry: reg, provider: provider} = start_infra()

      opts = [provider: provider, model: "claude-sonnet-4-20250514"]

      assert {:ok, _} = Supervisor.handle_message(sup, reg, "persist_group", "First", opts)
      assert {:ok, _} = Supervisor.handle_message(sup, reg, "persist_group", "Second", opts)

      # Only one session should exist for this group
      assert [{_pid, _}] = Registry.lookup(reg, "persist_group")
    end
  end

  describe "crash recovery" do
    test "crashed session is cleaned from Registry" do
      %{sup: sup, registry: reg, provider: provider} = start_infra()

      opts = [provider: provider, model: "claude-sonnet-4-20250514"]

      assert {:ok, _} = Supervisor.handle_message(sup, reg, "crash_group", "Hello", opts)
      [{pid, _}] = Registry.lookup(reg, "crash_group")

      # Kill the session process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Registry should be cleaned up
      assert [] = Registry.lookup(reg, "crash_group")
    end
  end
end
