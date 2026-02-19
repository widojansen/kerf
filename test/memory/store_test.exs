defmodule ExClaw.Memory.StoreTest do
  use ExUnit.Case, async: false

  alias ExClaw.Memory.Store
  alias ExClaw.Memory.Fact
  alias ExClaw.Memory.Message

  setup do
    # Set up Ecto Sandbox for this test process
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ExClaw.Repo)

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
    Ecto.Adapters.SQL.Sandbox.allow(ExClaw.Repo, self(), pid)

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
end
