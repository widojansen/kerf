defmodule Kerf.Container.SupervisorTest do
  use ExUnit.Case, async: true

  alias Kerf.Container.Supervisor, as: ContainerSup

  test "starts successfully" do
    opts = [
      name: :"container_sup_test_#{:rand.uniform(1_000_000)}",
      manager_opts: [
        workspaces_dir: System.tmp_dir!() |> Path.join("exclaw_sup_test_#{:rand.uniform(1_000_000)}"),
        docker_adapter: fn _args -> {"", 0} end,
        exec_timeout: 5_000
      ]
    ]

    assert {:ok, pid} = ContainerSup.start_link(opts)
    assert Process.alive?(pid)
    Supervisor.stop(pid)
  end

  test "starts Manager as a child" do
    manager_name = :"manager_test_#{:rand.uniform(1_000_000)}"

    opts = [
      name: :"container_sup_child_#{:rand.uniform(1_000_000)}",
      manager_opts: [
        name: manager_name,
        workspaces_dir: System.tmp_dir!() |> Path.join("exclaw_sup_child_#{:rand.uniform(1_000_000)}"),
        docker_adapter: fn _args -> {"", 0} end,
        exec_timeout: 5_000
      ]
    ]

    {:ok, pid} = ContainerSup.start_link(opts)
    children = Supervisor.which_children(pid)
    assert length(children) == 1

    [{_id, child_pid, :worker, _modules}] = children
    assert Process.alive?(child_pid)

    Supervisor.stop(pid)
  end

  test "Manager is accessible by registered name" do
    manager_name = :"manager_named_#{:rand.uniform(1_000_000)}"

    opts = [
      name: :"container_sup_named_#{:rand.uniform(1_000_000)}",
      manager_opts: [
        name: manager_name,
        workspaces_dir: System.tmp_dir!() |> Path.join("exclaw_sup_named_#{:rand.uniform(1_000_000)}"),
        docker_adapter: fn _args -> {"", 0} end,
        exec_timeout: 5_000
      ]
    ]

    {:ok, _pid} = ContainerSup.start_link(opts)

    assert {:ok, []} = Kerf.Container.Manager.list_containers(manager_name)

    Supervisor.stop(opts[:name])
  end
end
