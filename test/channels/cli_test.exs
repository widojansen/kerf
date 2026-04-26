defmodule Kerf.Channels.CLITest do
  use Kerf.DataCase

  alias Kerf.Channels.CLI
  alias Kerf.LLM.{Provider, RateLimiter}
  alias Kerf.Memory.Store

  # --- Anthropic response helpers (same shape as SessionTest) ---

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
    rl_name = :"test_rl_cli_#{suffix}"
    provider_name = :"test_provider_cli_#{suffix}"
    registry_name = :"test_registry_cli_#{suffix}"
    sup_name = :"test_sup_cli_#{suffix}"
    store_name = :"test_store_cli_#{suffix}"

    # Agent-based counter for sequenced responses
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
    {:ok, _} = Kerf.Agent.Supervisor.start_link(name: sup_name)

    # Ecto sandbox + Store for persistence tests

    tmp_dir = Path.join(System.tmp_dir!(), "exclaw_cli_test_#{suffix}")
    File.mkdir_p!(tmp_dir)

    {:ok, store_pid} =
      Store.start_link(
        name: store_name,
        data_dir: tmp_dir,
        repo: Kerf.Repo
      )

    allow_repo(store_pid)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{
      provider: provider_name,
      registry: registry_name,
      agent_supervisor: sup_name,
      store: store_name,
      tmp_dir: tmp_dir,
      group_id: Keyword.get(opts, :group_id, "cli_test_#{suffix}")
    }
  end

  # --- exit_command?/1 ---

  describe "exit_command?/1" do
    test "recognizes 'exit'" do
      assert CLI.exit_command?("exit")
    end

    test "recognizes 'quit'" do
      assert CLI.exit_command?("quit")
    end

    test "recognizes ':q'" do
      assert CLI.exit_command?(":q")
    end

    test "recognizes '/exit'" do
      assert CLI.exit_command?("/exit")
    end

    test "recognizes '/quit'" do
      assert CLI.exit_command?("/quit")
    end

    test "is case-insensitive" do
      assert CLI.exit_command?("EXIT")
      assert CLI.exit_command?("Quit")
      assert CLI.exit_command?(":Q")
    end

    test "trims whitespace" do
      assert CLI.exit_command?("  exit  ")
      assert CLI.exit_command?("\texit\n")
    end

    test "rejects regular messages" do
      refute CLI.exit_command?("hello")
      refute CLI.exit_command?("exit the loop")
      refute CLI.exit_command?("please quit doing that")
      refute CLI.exit_command?("")
    end
  end

  # --- build_system_prompt/2 ---

  describe "build_system_prompt/2" do
    test "returns base prompt when no MEMORY.md exists" do
      infra = start_infra([])

      prompt =
        CLI.build_system_prompt(infra.group_id,
          store: infra.store,
          base_prompt: "You are a test bot."
        )

      assert prompt == "You are a test bot."
    end

    test "appends MEMORY.md content to base prompt" do
      infra = start_infra([])

      :ok = Store.update_group(infra.store, infra.group_id, "User prefers short answers.")

      prompt =
        CLI.build_system_prompt(infra.group_id,
          store: infra.store,
          base_prompt: "You are a test bot."
        )

      assert prompt =~ "You are a test bot."
      assert prompt =~ "User prefers short answers."
    end

    test "uses config default for base_prompt when not provided" do
      infra = start_infra([])

      prompt = CLI.build_system_prompt(infra.group_id, store: infra.store)

      config_prompt = Application.get_env(:kerf, Kerf.Channels.CLI)[:base_prompt]
      assert prompt == config_prompt
    end
  end

  # --- process_input/3 ---

  describe "process_input/3" do
    test "successful response from agent" do
      infra = start_infra([text_response("Hello from CLI!")])

      assert {:respond, "Hello from CLI!"} =
               CLI.process_input("Hi there", infra.group_id,
                 agent_supervisor: infra.agent_supervisor,
                 registry: infra.registry,
                 provider: infra.provider,
                 model: "claude-sonnet-4-20250514",
                 tools: []
               )
    end

    test "returns error on LLM failure" do
      suffix = System.unique_integer([:positive])
      rl_name = :"test_rl_cli_err_#{suffix}"
      provider_name = :"test_provider_cli_err_#{suffix}"
      registry_name = :"test_registry_cli_err_#{suffix}"
      sup_name = :"test_sup_cli_err_#{suffix}"

      {:ok, _} = RateLimiter.start_link(name: rl_name, max_requests_per_minute: 0)

      {:ok, _} =
        Provider.start_link(
          name: provider_name,
          api_key: "test-key",
          adapter: fn req -> {req, Req.Response.json(text_response("nope"))} end,
          rate_limiter: rl_name
        )

      {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
      {:ok, _} = Kerf.Agent.Supervisor.start_link(name: sup_name)

      assert {:error, reason} =
               CLI.process_input("hello", "cli_err_#{suffix}",
                 agent_supervisor: sup_name,
                 registry: registry_name,
                 provider: provider_name,
                 model: "claude-sonnet-4-20250514",
                 tools: []
               )

      assert reason =~ "budget"
    end

    test "reuses session for same group_id" do
      infra =
        start_infra([
          text_response("First"),
          text_response("Second, with context")
        ])

      opts = [
        agent_supervisor: infra.agent_supervisor,
        registry: infra.registry,
        provider: infra.provider,
        model: "claude-sonnet-4-20250514",
        tools: []
      ]

      assert {:respond, "First"} = CLI.process_input("Hello", infra.group_id, opts)
      assert {:respond, "Second, with context"} = CLI.process_input("Follow up", infra.group_id, opts)
    end
  end

  # --- persist_exchange/4 ---

  describe "persist_exchange/4" do
    test "saves both user and assistant messages" do
      infra = start_infra([])

      assert :ok = CLI.persist_exchange(infra.group_id, "Hello", "Hi there!", store: infra.store)

      {:ok, messages} = Store.get_messages(infra.store, infra.group_id)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == "user"
      assert Enum.at(messages, 0).content == "Hello"
      assert Enum.at(messages, 1).role == "assistant"
      assert Enum.at(messages, 1).content == "Hi there!"
    end

    test "preserves chronological order across multiple exchanges" do
      infra = start_infra([])

      :ok = CLI.persist_exchange(infra.group_id, "First", "Reply 1", store: infra.store)
      :ok = CLI.persist_exchange(infra.group_id, "Second", "Reply 2", store: infra.store)

      {:ok, messages} = Store.get_messages(infra.store, infra.group_id)
      assert length(messages) == 4
      assert Enum.map(messages, & &1.role) == ["user", "assistant", "user", "assistant"]
      assert Enum.map(messages, & &1.content) == ["First", "Reply 1", "Second", "Reply 2"]
    end

    test "returns :ok if Store is unavailable" do
      # Use a name that doesn't exist — should not crash
      assert :ok = CLI.persist_exchange("grp", "msg", "reply", store: :nonexistent_store)
    end

    test "returns :ok on rate limit denial (Store still works)" do
      infra = start_infra([])

      # persist_exchange should always return :ok regardless of content
      assert :ok =
               CLI.persist_exchange(infra.group_id, "budget exceeded", "sorry", store: infra.store)

      {:ok, messages} = Store.get_messages(infra.store, infra.group_id)
      assert length(messages) == 2
    end
  end
end
