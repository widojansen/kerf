defmodule Kerf.Container.IntegrationTest do
  @moduledoc """
  Integration tests for Docker container sandboxing.
  Requires Docker to be installed and the sandbox image to be built:

      docker build -t kerf-sandbox:latest container/

  Run with: mix test --include docker
  """
  use ExUnit.Case, async: false

  @moduletag :docker

  alias Kerf.Container.Manager
  alias Kerf.Tools.{Shell, FileOps, Dispatcher}

  @image "kerf-sandbox:latest"

  # Generate a unique suffix per test run to avoid container name conflicts
  defp unique_id, do: :rand.uniform(1_000_000) |> to_string()

  setup_all do
    # Verify Docker is available and image exists
    case System.cmd("docker", ["image", "inspect", @image], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        raise """
        Docker integration tests require the sandbox image.
        Build it with: docker build -t kerf-sandbox:latest container/
        """
    end
  end

  setup do
    # Use project-relative path (under $HOME) — Docker Desktop on macOS
    # only shares certain host paths; /var/folders and /tmp may not work.
    project_root = Path.expand("../../..", __DIR__)
    workspaces_dir = Path.join(project_root, "priv/workspaces/integ_#{unique_id()}")
    File.mkdir_p!(workspaces_dir)

    {:ok, pid} = Manager.start_link(
      workspaces_dir: workspaces_dir,
      image: @image,
      exec_timeout: 30_000,
      max_output_size: 102_400,
      container_opts: [
        read_only: true,
        network: "none",
        memory: "512m",
        cpus: "1",
        pids_limit: 256,
        cap_drop: ["ALL"],
        cap_add: ["CHOWN"],
        security_opt: ["no-new-privileges"],
        tmpfs: ["/tmp:rw,noexec,nosuid,size=256m"],
        user: "1000:1000"
      ]
    )

    on_exit(fn ->
      # Resilient cleanup — Manager may already be stopped
      if Process.alive?(pid) do
        try do
          Manager.cleanup_all(pid)
        catch
          :exit, _ -> :ok
        end
      end

      # Belt-and-suspenders: force-remove any containers we created
      case System.cmd("docker", ["ps", "-a", "--filter", "name=kerf-", "--format", "{{.Names}}"],
             stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.each(fn name ->
            System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)
          end)
        _ -> :ok
      end

      File.rm_rf(workspaces_dir)
    end)

    %{manager: pid, workspaces_dir: workspaces_dir}
  end

  describe "container lifecycle" do
    test "creates and tracks a container", %{manager: manager} do
      group = "lifecycle_#{unique_id()}"
      assert {:ok, name} = Manager.ensure_container(manager, group)
      assert name =~ "kerf-"

      {:ok, containers} = Manager.list_containers(manager)
      assert length(containers) == 1
      assert hd(containers).group_id == group
    end

    test "container is idempotent", %{manager: manager} do
      group = "idempotent_#{unique_id()}"
      {:ok, name1} = Manager.ensure_container(manager, group)
      {:ok, name2} = Manager.ensure_container(manager, group)
      assert name1 == name2
    end

    test "cleanup removes the container", %{manager: manager} do
      group = "cleanup_#{unique_id()}"
      {:ok, name} = Manager.ensure_container(manager, group)
      assert :ok = Manager.cleanup(manager, group)

      # Verify container is actually gone
      {output, code} = System.cmd("docker", ["inspect", name], stderr_to_stdout: true)
      assert code != 0 or output =~ "No such object"
    end
  end

  describe "shell execution" do
    test "runs basic commands", %{manager: manager} do
      group = "shell_#{unique_id()}"
      opts = [container_manager: manager, group_id: group]
      assert {:ok, output} = Shell.execute(%{"command" => "echo hello"}, opts)
      assert String.trim(output) == "hello"
    end

    test "runs commands with pipes", %{manager: manager} do
      group = "pipes_#{unique_id()}"
      opts = [container_manager: manager, group_id: group]
      assert {:ok, output} = Shell.execute(%{"command" => "echo 'abc' | wc -c"}, opts)
      assert String.trim(output) =~ "4"
    end

    test "container is read-only (cannot write to /)", %{manager: manager} do
      group = "readonly_#{unique_id()}"
      opts = [container_manager: manager, group_id: group]
      {:error, reason} = Shell.execute(%{"command" => "touch /test_file"}, opts)
      assert reason =~ "Read-only" or reason =~ "exit code"
    end

    test "container has no network access", %{manager: manager} do
      group = "nonet_#{unique_id()}"
      opts = [container_manager: manager, group_id: group]
      # This should fail because network is disabled
      {:error, _reason} = Shell.execute(%{"command" => "curl -s --max-time 2 https://example.com"}, opts)
    end

    test "container runs as non-root", %{manager: manager} do
      group = "user_#{unique_id()}"
      opts = [container_manager: manager, group_id: group]
      {:ok, output} = Shell.execute(%{"command" => "id -u"}, opts)
      assert String.trim(output) == "1000"
    end
  end

  describe "file operations via bind mount" do
    test "write then read a file", %{workspaces_dir: dir} do
      group = "fileops_#{unique_id()}"
      group_dir = Path.join(dir, group)
      File.mkdir_p!(group_dir)

      opts = [workspaces_dir: dir, group_id: group]

      assert {:ok, _msg} = FileOps.write(%{"path" => "test.txt", "content" => "integration test"}, opts)
      assert {:ok, "integration test"} = FileOps.read(%{"path" => "test.txt"}, opts)
    end

    test "file written on host is visible inside container", %{manager: manager, workspaces_dir: dir} do
      group = "hostvis_#{unique_id()}"

      # Create the workspace dir first and write the file
      group_dir = Path.join(dir, group)
      File.mkdir_p!(group_dir)
      File.write!(Path.join(group_dir, "from_host.txt"), "host data")

      # Ensure container — this binds the workspace dir
      opts = [container_manager: manager, group_id: group]
      {:ok, output} = Shell.execute(%{"command" => "cat /workspace/from_host.txt"}, opts)
      assert String.trim(output) == "host data"
    end

    test "file written inside container is visible on host", %{manager: manager, workspaces_dir: dir} do
      group = "contwrite_#{unique_id()}"

      # Ensure the container creates the workspace dir
      opts = [container_manager: manager, group_id: group]

      # Write using /tmp (writable in container) then copy to workspace
      # The workspace is mounted as a volume, so writes there should be visible on host
      {:ok, _} = Shell.execute(%{"command" => "echo -n 'from container' > /workspace/container_file.txt"}, opts)

      group_dir = Path.join(dir, group)
      assert File.read!(Path.join(group_dir, "container_file.txt")) == "from container"
    end
  end

  describe "dispatcher integration" do
    test "build_executor dispatches all three tools", %{manager: manager, workspaces_dir: dir} do
      group = "dispatch_#{unique_id()}"
      group_dir = Path.join(dir, group)
      File.mkdir_p!(group_dir)

      executor = Dispatcher.build_executor(
        container_manager: manager,
        group_id: group,
        workspaces_dir: dir
      )

      # shell_exec
      {:ok, output} = executor.("shell_exec", %{"command" => "echo dispatch"})
      assert String.trim(output) == "dispatch"

      # file_write
      {:ok, _msg} = executor.("file_write", %{"path" => "d.txt", "content" => "dispatched"})

      # file_read
      {:ok, "dispatched"} = executor.("file_read", %{"path" => "d.txt"})
    end
  end
end
