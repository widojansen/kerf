defmodule ExClaw.Channels.WhatsAppTest do
  use ExUnit.Case, async: false

  alias ExClaw.Channels.WhatsApp
  alias ExClaw.LLM.{Provider, RateLimiter}
  alias ExClaw.Memory.Store

  # --- Anthropic response helpers (same shape as CLITest) ---

  defp anthropic_response(content_blocks, opts) do
    %{
      "id" => Keyword.get(opts, :id, "msg_test_#{System.unique_integer([:positive])}"),
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => content_blocks,
      "stop_reason" => Keyword.get(opts, :stop_reason, "end_turn"),
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 10),
        "output_tokens" => Keyword.get(opts, :output_tokens, 25)
      }
    }
  end

  defp text_response(text, opts \\ []) do
    anthropic_response([%{"type" => "text", "text" => text}], opts)
  end

  # --- Setup for integration tests ---

  defp start_infra(responses, opts \\ []) do
    suffix = System.unique_integer([:positive])
    rl_name = :"test_rl_wa_#{suffix}"
    provider_name = :"test_provider_wa_#{suffix}"
    registry_name = :"test_registry_wa_#{suffix}"
    sup_name = :"test_sup_wa_#{suffix}"
    store_name = :"test_store_wa_#{suffix}"

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      idx = Agent.get_and_update(counter, fn i -> {i, i + 1} end)
      body = Enum.at(responses, idx, text_response("fallback"))
      {request, Req.Response.json(body)}
    end

    {:ok, _} =
      RateLimiter.start_link(
        name: rl_name,
        max_requests_per_minute: 1000,
        max_tokens_per_minute: 1_000_000
      )

    {:ok, _} =
      Provider.start_link(
        name: provider_name,
        api_key: "test-key-not-real",
        base_url: "https://api.anthropic.com/v1",
        adapter: adapter,
        rate_limiter: rl_name
      )

    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
    {:ok, _} = ExClaw.Agent.Supervisor.start_link(name: sup_name)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ExClaw.Repo)

    tmp_dir = Path.join(System.tmp_dir!(), "exclaw_wa_test_#{suffix}")
    File.mkdir_p!(tmp_dir)

    {:ok, store_pid} =
      Store.start_link(
        name: store_name,
        data_dir: tmp_dir,
        repo: ExClaw.Repo
      )

    Ecto.Adapters.SQL.Sandbox.allow(ExClaw.Repo, self(), store_pid)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{
      provider: provider_name,
      registry: registry_name,
      agent_supervisor: sup_name,
      store: store_name,
      tmp_dir: tmp_dir,
      group_id: Keyword.get(opts, :group_id, "wa_test_#{suffix}")
    }
  end

  # ===================================================================
  # Pure function tests
  # ===================================================================

  describe "derive_group_id/2" do
    test "DM JID produces correct group_id" do
      event = %{"from" => "12345@s.whatsapp.net"}
      assert WhatsApp.derive_group_id(event, "wa") == "wa_12345"
    end

    test "group JID produces correct group_id" do
      event = %{"from" => "12345-67890@g.us"}
      assert WhatsApp.derive_group_id(event, "wa") == "wa_12345-67890_g"
    end

    test "special characters in JID are sanitized" do
      event = %{"from" => "abc/def:123@s.whatsapp.net"}
      result = WhatsApp.derive_group_id(event, "wa")
      # Should not contain / or : — replaced with _
      refute result =~ "/"
      refute result =~ ":"
      assert result =~ "wa_"
    end

    test "JID with device suffix handled" do
      event = %{"from" => "12345:0@s.whatsapp.net"}
      result = WhatsApp.derive_group_id(event, "wa")
      assert result =~ "wa_"
    end
  end

  describe "should_process_message?/2" do
    test "skips fromMe messages" do
      event = %{"fromMe" => true, "text" => "hello", "from" => "123@s.whatsapp.net"}
      config = %{mention_required: false}
      refute WhatsApp.should_process_message?(event, config)
    end

    test "skips empty text" do
      event = %{"fromMe" => false, "text" => "", "from" => "123@s.whatsapp.net"}
      config = %{mention_required: false}
      refute WhatsApp.should_process_message?(event, config)
    end

    test "skips nil text" do
      event = %{"fromMe" => false, "text" => nil, "from" => "123@s.whatsapp.net"}
      config = %{mention_required: false}
      refute WhatsApp.should_process_message?(event, config)
    end

    test "skips status broadcast" do
      event = %{"fromMe" => false, "text" => "hello", "from" => "status@broadcast"}
      config = %{mention_required: false}
      refute WhatsApp.should_process_message?(event, config)
    end

    test "accepts valid DM message" do
      event = %{"fromMe" => false, "text" => "hello", "from" => "123@s.whatsapp.net", "isGroup" => false}
      config = %{mention_required: false}
      assert WhatsApp.should_process_message?(event, config)
    end

    test "accepts valid group message when mention not required" do
      event = %{"fromMe" => false, "text" => "hello", "from" => "123@g.us", "isGroup" => true}
      config = %{mention_required: false}
      assert WhatsApp.should_process_message?(event, config)
    end
  end

  describe "parse_event/1" do
    test "parses valid JSON" do
      assert {:ok, %{"type" => "ready"}} = WhatsApp.parse_event(~s({"type":"ready"}))
    end

    test "returns error for invalid JSON" do
      assert {:error, _reason} = WhatsApp.parse_event("not json")
    end

    test "returns error for empty string" do
      assert {:error, _reason} = WhatsApp.parse_event("")
    end
  end

  describe "build_send_command/2" do
    test "builds correct command map" do
      cmd = WhatsApp.build_send_command("12345@s.whatsapp.net", "Hello!")
      assert cmd["type"] == "send"
      assert cmd["to"] == "12345@s.whatsapp.net"
      assert cmd["text"] == "Hello!"
      assert is_binary(cmd["id"])
    end

    test "generates unique IDs" do
      cmd1 = WhatsApp.build_send_command("jid", "a")
      cmd2 = WhatsApp.build_send_command("jid", "b")
      assert cmd1["id"] != cmd2["id"]
    end
  end

  # ===================================================================
  # GenServer lifecycle tests
  # ===================================================================

  describe "GenServer lifecycle" do
    test "starts with status :starting" do
      wa_name = :"test_wa_lifecycle_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end
        )

      assert Process.alive?(pid)
      assert WhatsApp.status(wa_name) == :starting
    end

    test "handles connected event — updates status and user_info" do
      wa_name = :"test_wa_connected_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end
        )

      event = ~s({"type":"connected","user":{"id":"12345@s.whatsapp.net","name":"TestBot"}})
      send(wa_name, {:simulate_event, event})

      # Give GenServer time to process
      Process.sleep(50)

      assert WhatsApp.status(wa_name) == :connected
      info = WhatsApp.get_info(wa_name)
      assert info.user_info["id"] == "12345@s.whatsapp.net"
    end

    test "handles qr event — updates status to :waiting_qr" do
      wa_name = :"test_wa_qr_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end
        )

      send(wa_name, {:simulate_event, ~s({"type":"qr","data":"2@abc123"})})
      Process.sleep(50)

      assert WhatsApp.status(wa_name) == :waiting_qr
    end

    test "handles disconnected event — updates status" do
      wa_name = :"test_wa_disconnected_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end
        )

      # First connect, then disconnect
      send(wa_name, {:simulate_event, ~s({"type":"connected","user":{"id":"1@s.whatsapp.net"}})})
      Process.sleep(50)
      assert WhatsApp.status(wa_name) == :connected

      send(wa_name, {:simulate_event, ~s({"type":"disconnected","reason":"network","code":428})})
      Process.sleep(50)
      assert WhatsApp.status(wa_name) == :disconnected
    end

    test "handles logged_out event — stops GenServer" do
      wa_name = :"test_wa_logout_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end
        )

      ref = Process.monitor(pid)

      send(wa_name, {:simulate_event, ~s({"type":"logged_out"})})

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end

    test "get_info/1 returns status and config" do
      wa_name = :"test_wa_info_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end,
          group_id_prefix: "wa",
          model: "claude-sonnet-4-20250514"
        )

      info = WhatsApp.get_info(wa_name)
      assert info.status == :starting
      assert info.config.group_id_prefix == "wa"
    end
  end

  # ===================================================================
  # Message routing tests
  # ===================================================================

  describe "message routing" do
    test "routes incoming message to Agent.Supervisor and persists exchange" do
      infra = start_infra([text_response("WhatsApp reply!")])
      wa_name = :"test_wa_route_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        WhatsApp.start_link(
          name: wa_name,
          port_opener: fn _cmd, _args, _opts -> nil end,
          agent_supervisor: infra.agent_supervisor,
          registry: infra.registry,
          provider: infra.provider,
          store: infra.store,
          model: "claude-sonnet-4-20250514",
          group_id_prefix: "wa",
          base_prompt: "You are a test bot."
        )

      # Mark as connected first
      send(wa_name, {:simulate_event, ~s({"type":"connected","user":{"id":"bot@s.whatsapp.net"}})})
      Process.sleep(50)

      # Simulate incoming message
      msg_event = Jason.encode!(%{
        "type" => "message",
        "id" => "MSG001",
        "from" => "55512345@s.whatsapp.net",
        "participant" => nil,
        "pushName" => "John",
        "text" => "Hello from WhatsApp",
        "timestamp" => 1708300000,
        "isGroup" => false
      })

      send(wa_name, {:simulate_event, msg_event})

      # Wait for async processing (agent call + response)
      Process.sleep(500)

      # Verify an Agent.Session was created for this group_id
      group_id = "wa_55512345"
      sessions = Registry.lookup(infra.registry, group_id)
      assert length(sessions) == 1

      # Verify exchange was persisted
      {:ok, messages} = Store.get_messages(infra.store, group_id)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == "user"
      assert Enum.at(messages, 0).content == "Hello from WhatsApp"
      assert Enum.at(messages, 1).role == "assistant"
      assert Enum.at(messages, 1).content == "WhatsApp reply!"
    end
  end
end
