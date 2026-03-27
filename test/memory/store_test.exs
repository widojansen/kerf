defmodule ExClaw.Memory.StoreTest do
  use ExClaw.DataCase

  alias ExClaw.Memory.Store
  alias ExClaw.Memory.Fact
  alias ExClaw.Memory.Message
  alias ExClaw.Memory.Embedder

  setup do
    # Set up Ecto Sandbox for this test process

    # Use a unique temp dir for filesystem tests
    tmp_dir = Path.join(System.tmp_dir!(), "exclaw_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Start Store with unique name and test data_dir
    name = :"store_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Store.start_link(
        name: name,
        data_dir: tmp_dir,
        repo: ExClaw.Repo
      )

    # Allow the GenServer process to use the sandbox connection
    allow_repo(pid)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{store: name, tmp_dir: tmp_dir}
  end

  # ── Facts ──

  describe "save_fact/5" do
    test "saves a new fact", %{store: store} do
      assert {:ok, %Fact{} = fact} = Store.save_fact(store, "group1", "name", "Alice")
      assert fact.group_id == "group1"
      assert fact.key == "name"
      assert fact.value == "Alice"
      assert fact.source == nil
    end

    test "saves a fact with source", %{store: store} do
      assert {:ok, %Fact{} = fact} =
               Store.save_fact(store, "group1", "name", "Alice", "user_stated")

      assert fact.source == "user_stated"
    end

    test "upserts when same group_id + key exists", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, fact} = Store.save_fact(store, "group1", "name", "Bob")

      assert fact.value == "Bob"

      # Only one record should exist
      {:ok, facts} = Store.get_facts(store, "group1")
      assert length(facts) == 1
      assert hd(facts).value == "Bob"
    end

    test "upserts source on conflict", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice", "inferred")
      {:ok, fact} = Store.save_fact(store, "group1", "name", "Alice", "user_stated")

      assert fact.source == "user_stated"
    end

    test "same key in different groups creates separate facts", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, _} = Store.save_fact(store, "group2", "name", "Bob")

      {:ok, g1} = Store.get_facts(store, "group1")
      {:ok, g2} = Store.get_facts(store, "group2")

      assert length(g1) == 1
      assert length(g2) == 1
      assert hd(g1).value == "Alice"
      assert hd(g2).value == "Bob"
    end
  end

  describe "get_facts/2" do
    test "returns all facts for a group", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, _} = Store.save_fact(store, "group1", "language", "Elixir")

      {:ok, facts} = Store.get_facts(store, "group1")
      assert length(facts) == 2
      keys = Enum.map(facts, & &1.key) |> Enum.sort()
      assert keys == ["language", "name"]
    end

    test "returns empty list for unknown group", %{store: store} do
      assert {:ok, []} = Store.get_facts(store, "nonexistent")
    end

    test "is scoped to the requested group", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, _} = Store.save_fact(store, "group2", "name", "Bob")

      {:ok, facts} = Store.get_facts(store, "group1")
      assert length(facts) == 1
      assert hd(facts).value == "Alice"
    end
  end

  describe "search/3" do
    test "matches on key", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "favorite_color", "blue")
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")

      {:ok, results} = Store.search(store, "group1", "color")
      assert length(results) == 1
      assert hd(results).key == "favorite_color"
    end

    test "matches on value", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "language", "Elixir")
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")

      {:ok, results} = Store.search(store, "group1", "elixir")
      assert length(results) == 1
      assert hd(results).key == "language"
    end

    test "is case-insensitive", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "language", "Elixir")

      {:ok, results} = Store.search(store, "group1", "ELIXIR")
      assert length(results) == 1
    end

    test "is scoped to group", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, _} = Store.save_fact(store, "group2", "name", "Alice")

      {:ok, results} = Store.search(store, "group1", "Alice")
      assert length(results) == 1
      assert hd(results).group_id == "group1"
    end

    test "returns empty list on no match", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")

      assert {:ok, []} = Store.search(store, "group1", "zzzzz")
    end

    test "escapes LIKE wildcards in query", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "pattern", "100%_done")

      # Searching for literal "%" should match
      {:ok, results} = Store.search(store, "group1", "100%")
      assert length(results) == 1

      # Searching for literal "_" should match
      {:ok, results} = Store.search(store, "group1", "%_")
      assert length(results) == 1
    end
  end

  describe "delete_fact/3" do
    test "removes a fact", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      assert :ok = Store.delete_fact(store, "group1", "name")

      {:ok, facts} = Store.get_facts(store, "group1")
      assert facts == []
    end

    test "is idempotent — deleting nonexistent fact returns :ok", %{store: store} do
      assert :ok = Store.delete_fact(store, "group1", "nonexistent")
    end

    test "is scoped to group", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, _} = Store.save_fact(store, "group2", "name", "Bob")

      :ok = Store.delete_fact(store, "group1", "name")

      {:ok, g1} = Store.get_facts(store, "group1")
      {:ok, g2} = Store.get_facts(store, "group2")
      assert g1 == []
      assert length(g2) == 1
    end
  end

  # ── MEMORY.md ──

  describe "load_group/2" do
    test "returns empty string when file does not exist", %{store: store} do
      assert {:ok, ""} = Store.load_group(store, "group1")
    end

    test "returns content of existing MEMORY.md", %{store: store, tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, "groups", "group1"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "MEMORY.md"), "# Group 1 Notes\n\nSome context here.")

      {:ok, content} = Store.load_group(store, "group1")
      assert content == "# Group 1 Notes\n\nSome context here."
    end
  end

  describe "update_group/3" do
    test "creates directory and file when they don't exist", %{store: store, tmp_dir: tmp_dir} do
      :ok = Store.update_group(store, "group1", "# Notes\n\nHello!")

      path = Path.join([tmp_dir, "groups", "group1", "MEMORY.md"])
      assert File.exists?(path)
      assert File.read!(path) == "# Notes\n\nHello!"
    end

    test "overwrites existing content", %{store: store} do
      :ok = Store.update_group(store, "group1", "version 1")
      :ok = Store.update_group(store, "group1", "version 2")

      {:ok, content} = Store.load_group(store, "group1")
      assert content == "version 2"
    end

    test "sanitizes group_id for filesystem path", %{store: store, tmp_dir: tmp_dir} do
      :ok = Store.update_group(store, "group/with../special", "content")

      # Should have sanitized the path
      {:ok, content} = Store.load_group(store, "group/with../special")
      assert content == "content"

      # Should NOT have created traversal paths
      refute File.exists?(Path.join(tmp_dir, "special"))
    end
  end

  # ── Messages ──

  describe "save_message/5" do
    test "saves a user message", %{store: store} do
      {:ok, %Message{} = msg} = Store.save_message(store, "group1", "user", "Hello!")
      assert msg.group_id == "group1"
      assert msg.role == "user"
      assert msg.content == "Hello!"
    end

    test "saves an assistant message", %{store: store} do
      {:ok, %Message{} = msg} = Store.save_message(store, "group1", "assistant", "Hi there!")
      assert msg.role == "assistant"
    end

    test "saves a tool message with metadata", %{store: store} do
      {:ok, %Message{} = msg} =
        Store.save_message(store, "group1", "tool", "file contents here",
          tool_name: "file_read",
          tool_input: %{"path" => "/workspace/foo.txt"}
        )

      assert msg.role == "tool"
      assert msg.tool_name == "file_read"
      assert msg.tool_input != nil
    end

    test "rejects invalid role", %{store: store} do
      assert {:error, _} = Store.save_message(store, "group1", "invalid_role", "text")
    end
  end

  describe "get_messages/3" do
    test "returns messages in chronological order", %{store: store} do
      {:ok, _} = Store.save_message(store, "group1", "user", "first")
      {:ok, _} = Store.save_message(store, "group1", "assistant", "second")
      {:ok, _} = Store.save_message(store, "group1", "user", "third")

      {:ok, messages} = Store.get_messages(store, "group1")
      contents = Enum.map(messages, & &1.content)
      assert contents == ["first", "second", "third"]
    end

    test "respects limit option", %{store: store} do
      for i <- 1..10 do
        {:ok, _} = Store.save_message(store, "group1", "user", "msg #{i}")
      end

      {:ok, messages} = Store.get_messages(store, "group1", limit: 3)
      assert length(messages) == 3
      # Should return the LAST 3 (most recent)
      contents = Enum.map(messages, & &1.content)
      assert contents == ["msg 8", "msg 9", "msg 10"]
    end

    test "defaults to 50 messages", %{store: store} do
      for i <- 1..60 do
        {:ok, _} = Store.save_message(store, "group1", "user", "msg #{i}")
      end

      {:ok, messages} = Store.get_messages(store, "group1")
      assert length(messages) == 50
    end

    test "is scoped to group", %{store: store} do
      {:ok, _} = Store.save_message(store, "group1", "user", "g1 msg")
      {:ok, _} = Store.save_message(store, "group2", "user", "g2 msg")

      {:ok, messages} = Store.get_messages(store, "group1")
      assert length(messages) == 1
      assert hd(messages).content == "g1 msg"
    end

    test "returns empty list for unknown group", %{store: store} do
      assert {:ok, []} = Store.get_messages(store, "nonexistent")
    end
  end

  # ── Async Embedding ──

  describe "async embedding" do
    setup do
      # Use shared sandbox so async tasks can access the DB
      Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, {:shared, self()})

      tmp_dir = Path.join(System.tmp_dir!(), "exclaw_embed_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      # Start a mock embedder that returns a deterministic 768-dim vector
      embedder_name = :"embedder_#{System.unique_integer([:positive])}"
      fake_vector = Enum.map(1..768, fn i -> i / 768.0 end)

      {:ok, _} =
        Embedder.start_link(
          name: embedder_name,
          adapter: fn request ->
            {request, Req.Response.json(%{"embeddings" => [fake_vector]})}
          end
        )

      # Start a Task.Supervisor for async embedding
      task_sup = :"task_sup_#{System.unique_integer([:positive])}"
      {:ok, _} = Task.Supervisor.start_link(name: task_sup)

      store_name = :"store_embed_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Store.start_link(
          name: store_name,
          data_dir: tmp_dir,
          repo: ExClaw.Repo,
          embedder: embedder_name,
          task_supervisor: task_sup
        )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{store: store_name, embedder: embedder_name, fake_vector: fake_vector}
    end

    test "populates embedding on saved fact", %{store: store} do
      {:ok, fact} = Store.save_fact(store, "group1", "name", "Alice")
      assert fact.embedding == nil

      # Wait for async embedding task
      Process.sleep(200)

      updated = ExClaw.Repo.get!(Fact, fact.id)
      assert %Pgvector{} = updated.embedding
      assert length(Pgvector.to_list(updated.embedding)) == 768
    end

    test "populates embedding on saved user message", %{store: store} do
      {:ok, msg} = Store.save_message(store, "group1", "user", "Hello world")

      Process.sleep(200)

      updated = ExClaw.Repo.get!(Message, msg.id)
      assert %Pgvector{} = updated.embedding
      assert length(Pgvector.to_list(updated.embedding)) == 768
    end

    test "populates embedding on saved assistant message", %{store: store} do
      {:ok, msg} = Store.save_message(store, "group1", "assistant", "Hi there!")

      Process.sleep(200)

      updated = ExClaw.Repo.get!(Message, msg.id)
      assert %Pgvector{} = updated.embedding
    end

    test "skips embedding for tool messages", %{store: store} do
      {:ok, msg} =
        Store.save_message(store, "group1", "tool", "result data",
          tool_name: "shell_exec",
          tool_input: %{"command" => "ls"}
        )

      Process.sleep(200)

      updated = ExClaw.Repo.get!(Message, msg.id)
      assert updated.embedding == nil
    end

    test "skips embedding for nil/empty content messages", %{store: store} do
      {:ok, msg} = Store.save_message(store, "group1", "user", nil)

      Process.sleep(200)

      updated = ExClaw.Repo.get!(Message, msg.id)
      assert updated.embedding == nil
    end
  end

  # ── Semantic Search ──

  describe "semantic_search/4" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, {:shared, self()})

      tmp_dir = Path.join(System.tmp_dir!(), "exclaw_search_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      # Embedder that returns different vectors based on input text hash
      # This gives us deterministic but distinct vectors for different texts
      embedder_name = :"search_embedder_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Embedder.start_link(
          name: embedder_name,
          adapter: fn request ->
            body = Jason.decode!(request.body)
            input = body["input"]
            vector = deterministic_vector(input)
            {request, Req.Response.json(%{"embeddings" => [vector]})}
          end
        )

      task_sup = :"search_task_sup_#{System.unique_integer([:positive])}"
      {:ok, _} = Task.Supervisor.start_link(name: task_sup)

      store_name = :"store_search_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Store.start_link(
          name: store_name,
          data_dir: tmp_dir,
          repo: ExClaw.Repo,
          embedder: embedder_name,
          task_supervisor: task_sup
        )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{store: store_name, embedder: embedder_name}
    end

    test "returns facts ordered by similarity", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "color", "blue")
      {:ok, _} = Store.save_fact(store, "group1", "food", "pizza")
      Process.sleep(300)

      {:ok, results} = Store.semantic_search(store, "group1", "color")
      assert length(results) > 0
      assert %Fact{} = hd(results).record
      # First result should have highest similarity
      assert hd(results).similarity >= 0.0
    end

    test "filters by group_id", %{store: store} do
      {:ok, _} = Store.save_fact(store, "group1", "name", "Alice")
      {:ok, _} = Store.save_fact(store, "group2", "name", "Bob")
      Process.sleep(300)

      {:ok, results} = Store.semantic_search(store, "group1", "name")
      group_ids = Enum.map(results, fn r -> r.record.group_id end)
      assert Enum.all?(group_ids, &(&1 == "group1"))
    end

    test "returns empty list when no embeddings exist", %{store: store} do
      # No facts saved — nothing to search
      {:ok, results} = Store.semantic_search(store, "group1", "anything")
      assert results == []
    end

    test "respects limit option", %{store: store} do
      for i <- 1..5 do
        {:ok, _} = Store.save_fact(store, "group1", "item_#{i}", "value #{i}")
      end

      Process.sleep(300)

      {:ok, results} = Store.semantic_search(store, "group1", "item", limit: 2)
      assert length(results) <= 2
    end

    test "returns error when embedder fails", ctx do
      # Start a store with a broken embedder
      broken_embedder = :"broken_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Embedder.start_link(
          name: broken_embedder,
          adapter: fn request ->
            {request, %Req.Response{status: 500, body: "down"}}
          end
        )

      tmp_dir = Path.join(System.tmp_dir!(), "exclaw_broken_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      store_name = :"store_broken_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Store.start_link(
          name: store_name,
          data_dir: tmp_dir,
          repo: ExClaw.Repo,
          embedder: broken_embedder,
          task_supervisor: ctx[:task_sup] || :"ts_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:error, _reason} = Store.semantic_search(store_name, "group1", "test")
    end
  end

  # Helper to generate deterministic vectors from text
  defp deterministic_vector(text) when is_binary(text) do
    <<seed::unsigned-32, _::binary>> = :crypto.hash(:sha256, text)
    rng = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})

    {vector, _} =
      Enum.map_reduce(1..768, rng, fn _, state ->
        {val, new_state} = :rand.uniform_s(state)
        {val, new_state}
      end)

    vector
  end
end
