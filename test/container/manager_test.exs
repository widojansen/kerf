defmodule Kerf.Container.ManagerTest do
  use ExUnit.Case, async: true

  alias Kerf.Container.Manager

  # --- Test Helpers ---

  defp start_manager(opts \\ []) do
    workspaces_dir = Keyword.get(opts, :workspaces_dir, System.tmp_dir!() |> Path.join("exclaw_test_#{:rand.uniform(1_000_000)}"))
    File.mkdir_p!(workspaces_dir)

    mock_adapter = Keyword.get(opts, :docker_adapter, &default_mock_adapter/1)

    manager_opts = [
      name: Keyword.get(opts, :name, nil),
      workspaces_dir: workspaces_dir,
      image: "exclaw-sandbox:latest",
      docker_adapter: mock_adapter,
      exec_timeout: 5_000,
      max_output_size: 1024,
      container_opts: [
        read_only: true,
        network: "none",
        memory: "512m",
        cpus: "1",
        pids_limit: 256,
        cap_drop: ["ALL"],
        security_opt: ["no-new-privileges"],
        tmpfs: ["/tmp:rw,noexec,nosuid,size=256m"],
        user: "1000:1000"
      ]
    ]

    {:ok, pid} = Manager.start_link(manager_opts)
    on_exit(fn ->
      File.rm_rf(workspaces_dir)
    end)
    {pid, workspaces_dir}
  end

  # Default mock: docker create/start/exec all succeed, inspect returns running
  defp default_mock_adapter(args) do
    case args do
      ["create" | _] -> {"container_id_abc123\n", 0}
      ["start" | _] -> {"container_id_abc123\n", 0}
      ["exec" | _] -> {"mock output\n", 0}
      ["inspect" | _] -> {"true\n", 0}
      ["rm" | _] -> {"", 0}
      _ -> {"", 0}
    end
  end

  # --- Tests ---

  describe "start_link/1" do
    test "starts the GenServer" do
      {pid, _dir} = start_manager()
      assert Process.alive?(pid)
    end

    test "starts with empty container map" do
      {pid, _dir} = start_manager()
      assert {:ok, []} = Manager.list_containers(pid)
    end
  end

  describe "ensure_container/2" do
    test "creates a container on first call" do
      create_called = :counters.new(1, [:atomics])

      adapter = fn args ->
        case args do
          ["create" | _] ->
            :counters.add(create_called, 1, 1)
            {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _] -> {"true\n", 0}
          _ -> {"", 0}
        end
      end

      {pid, _dir} = start_manager(docker_adapter: adapter)
      assert {:ok, container_name} = Manager.ensure_container(pid, "group1")
      assert container_name =~ "exclaw-"
      assert :counters.get(create_called, 1) == 1
    end

    test "is idempotent — returns same container on second call" do
      create_count = :counters.new(1, [:atomics])

      adapter = fn args ->
        case args do
          ["create" | _] ->
            :counters.add(create_count, 1, 1)
            {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _] -> {"true\n", 0}
          _ -> {"", 0}
        end
      end

      {pid, _dir} = start_manager(docker_adapter: adapter)
      {:ok, name1} = Manager.ensure_container(pid, "group1")
      {:ok, name2} = Manager.ensure_container(pid, "group1")
      assert name1 == name2
      # docker create called only once, second call just inspects
      assert :counters.get(create_count, 1) == 1
    end

    test "recreates container if health check shows it's dead" do
      call_log = :ets.new(:call_log, [:bag, :public])

      adapter = fn args ->
        :ets.insert(call_log, {args})
        case args do
          ["create" | _] -> {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _rest] ->
            # First inspect returns false (dead), triggering recreate
            count = :ets.match(call_log, {["inspect" | :_]}) |> length()
            if count <= 1, do: {"false\n", 0}, else: {"true\n", 0}
          ["rm" | _] -> {"", 0}
          _ -> {"", 0}
        end
      end

      {pid, _dir} = start_manager(docker_adapter: adapter)
      {:ok, _name} = Manager.ensure_container(pid, "group1")

      # Second ensure triggers inspect which shows dead → rm + recreate
      {:ok, _name2} = Manager.ensure_container(pid, "group1")

      rm_calls = :ets.match(call_log, {["rm" | :_]}) |> length()
      assert rm_calls >= 1
    end

    test "creates workspace directory for the group" do
      {pid, workspaces_dir} = start_manager()
      Manager.ensure_container(pid, "group1")

      # Workspace dir should be created (sanitized group_id)
      assert File.dir?(Path.join(workspaces_dir, "group1"))
    end

    test "sanitizes group_id for container name and workspace path" do
      {pid, workspaces_dir} = start_manager()
      {:ok, container_name} = Manager.ensure_container(pid, "my/bad group!!")

      # Container name should only have safe characters
      refute String.contains?(container_name, "/")
      refute String.contains?(container_name, "!")
      refute String.contains?(container_name, " ")

      # Workspace dir should use sanitized name
      entries = File.ls!(workspaces_dir)
      assert Enum.all?(entries, fn e -> e =~ ~r/^[a-zA-Z0-9_\-]+$/ end)
    end

    test "returns error when docker create fails" do
      adapter = fn args ->
        case args do
          ["create" | _] -> {"Error: image not found\n", 1}
          _ -> {"", 0}
        end
      end

      {pid, _dir} = start_manager(docker_adapter: adapter)
      assert {:error, reason} = Manager.ensure_container(pid, "group1")
      assert reason =~ "image not found" or reason =~ "docker create failed"
    end
  end

  describe "exec/3" do
    test "executes command in container" do
      adapter = fn args ->
        case args do
          ["create" | _] -> {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _] -> {"true\n", 0}
          ["exec" | rest] ->
            # Find the command after "sh" "-c"
            command = List.last(rest)
            {"ran: #{command}\n", 0}
          _ -> {"", 0}
        end
      end

      {pid, _dir} = start_manager(docker_adapter: adapter)
      assert {:ok, output} = Manager.exec(pid, "group1", "echo hello")
      assert output =~ "echo hello"
    end

    test "returns error on non-zero exit code" do
      adapter = fn args ->
        case args do
          ["create" | _] -> {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _] -> {"true\n", 0}
          ["exec" | _] -> {"command not found\n", 127}
          _ -> {"", 0}
        end
      end

      {pid, _dir} = start_manager(docker_adapter: adapter)
      assert {:error, reason} = Manager.exec(pid, "group1", "bad_command")
      assert reason =~ "exit code 127" or reason =~ "command not found"
    end

    test "truncates output exceeding max_output_size" do
      large_output = String.duplicate("x", 2048)

      adapter = fn args ->
        case args do
          ["create" | _] -> {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _] -> {"true\n", 0}
          ["exec" | _] -> {large_output, 0}
          _ -> {"", 0}
        end
      end

      # max_output_size is 1024 in our test config
      {pid, _dir} = start_manager(docker_adapter: adapter)
      {:ok, output} = Manager.exec(pid, "group1", "big_output")
      assert byte_size(output) <= 1024 + 100  # allow for truncation message
      assert output =~ "truncated"
    end
  end

  describe "cleanup/2" do
    test "removes container and clears from tracked map" do
      {pid, _dir} = start_manager()
      {:ok, _name} = Manager.ensure_container(pid, "group1")

      {:ok, containers} = Manager.list_containers(pid)
      assert length(containers) == 1

      assert :ok = Manager.cleanup(pid, "group1")

      {:ok, containers} = Manager.list_containers(pid)
      assert containers == []
    end

    test "returns :ok even if group has no container" do
      {pid, _dir} = start_manager()
      assert :ok = Manager.cleanup(pid, "nonexistent")
    end
  end

  describe "cleanup_all/1" do
    test "removes all tracked containers" do
      {pid, _dir} = start_manager()
      {:ok, _} = Manager.ensure_container(pid, "group1")
      {:ok, _} = Manager.ensure_container(pid, "group2")

      {:ok, containers} = Manager.list_containers(pid)
      assert length(containers) == 2

      assert :ok = Manager.cleanup_all(pid)

      {:ok, containers} = Manager.list_containers(pid)
      assert containers == []
    end
  end

  describe "list_containers/1" do
    test "returns container info with group_id, name, and created_at" do
      {pid, _dir} = start_manager()
      {:ok, _} = Manager.ensure_container(pid, "group1")

      {:ok, [container]} = Manager.list_containers(pid)
      assert container.group_id == "group1"
      assert is_binary(container.container_name)
      assert %DateTime{} = container.created_at
    end
  end
end
