defmodule Kerf.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias Kerf.Tools.Shell

  defp start_mock_manager(opts \\ []) do
    adapter = Keyword.get(opts, :docker_adapter, fn args ->
      case args do
        ["create" | _] -> {"container_abc\n", 0}
        ["start" | _] -> {"container_abc\n", 0}
        ["inspect" | _] -> {"true\n", 0}
        ["exec" | rest] ->
          command = List.last(rest)
          {"output of: #{command}\n", 0}
        _ -> {"", 0}
      end
    end)

    workspaces_dir = System.tmp_dir!() |> Path.join("exclaw_shell_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(workspaces_dir)

    {:ok, pid} = Kerf.Container.Manager.start_link(
      workspaces_dir: workspaces_dir,
      image: "exclaw-sandbox:latest",
      docker_adapter: adapter,
      exec_timeout: 5_000,
      max_output_size: 102_400,
      container_opts: []
    )

    on_exit(fn -> File.rm_rf(workspaces_dir) end)
    pid
  end

  describe "execute/2" do
    test "runs a command and returns output" do
      manager = start_mock_manager()
      opts = [container_manager: manager, group_id: "test_group"]

      assert {:ok, output} = Shell.execute(%{"command" => "echo hello"}, opts)
      assert output =~ "echo hello"
    end

    test "returns error when command key is missing" do
      manager = start_mock_manager()
      opts = [container_manager: manager, group_id: "test_group"]

      assert {:error, reason} = Shell.execute(%{}, opts)
      assert reason =~ "command" or reason =~ "missing"
    end

    test "returns error when docker exec fails" do
      adapter = fn args ->
        case args do
          ["create" | _] -> {"container_abc\n", 0}
          ["start" | _] -> {"container_abc\n", 0}
          ["inspect" | _] -> {"true\n", 0}
          ["exec" | _] -> {"permission denied\n", 1}
          _ -> {"", 0}
        end
      end

      manager = start_mock_manager(docker_adapter: adapter)
      opts = [container_manager: manager, group_id: "test_group"]

      assert {:error, reason} = Shell.execute(%{"command" => "rm -rf /"}, opts)
      assert reason =~ "exit code" or reason =~ "permission denied"
    end

    test "passes through container manager errors" do
      adapter = fn args ->
        case args do
          ["create" | _] -> {"image not found\n", 1}
          _ -> {"", 0}
        end
      end

      manager = start_mock_manager(docker_adapter: adapter)
      opts = [container_manager: manager, group_id: "test_group"]

      assert {:error, reason} = Shell.execute(%{"command" => "ls"}, opts)
      assert reason =~ "image not found" or reason =~ "docker create failed"
    end
  end
end
