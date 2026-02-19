defmodule ExClaw.Memory.SupervisorTest do
  use ExUnit.Case, async: false

  alias ExClaw.Memory.Supervisor, as: MemSup

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ExClaw.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, {:shared, self()})

    tmp_dir = Path.join(System.tmp_dir!(), "exclaw_sup_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "starts Store under supervision", %{tmp_dir: tmp_dir} do
    store_name = :"mem_store_#{System.unique_integer([:positive])}"
    sup_name = :"mem_sup_#{System.unique_integer([:positive])}"

    {:ok, sup_pid} =
      MemSup.start_link(
        name: sup_name,
        store_name: store_name,
        data_dir: tmp_dir,
        repo: ExClaw.Repo
      )

    assert Process.alive?(sup_pid)

    # Store should be running
    store_pid = GenServer.whereis(store_name)
    assert store_pid != nil
    assert Process.alive?(store_pid)
  end

  test "restarts Store on crash", %{tmp_dir: tmp_dir} do
    store_name = :"mem_store_#{System.unique_integer([:positive])}"
    sup_name = :"mem_sup_#{System.unique_integer([:positive])}"

    {:ok, _sup_pid} =
      MemSup.start_link(
        name: sup_name,
        store_name: store_name,
        data_dir: tmp_dir,
        repo: ExClaw.Repo
      )

    old_pid = GenServer.whereis(store_name)
    Process.exit(old_pid, :kill)

    # Give supervisor time to restart
    Process.sleep(50)

    new_pid = GenServer.whereis(store_name)
    assert new_pid != nil
    assert new_pid != old_pid
    assert Process.alive?(new_pid)
  end

  test "Store is functional after restart", %{tmp_dir: tmp_dir} do
    store_name = :"mem_store_#{System.unique_integer([:positive])}"
    sup_name = :"mem_sup_#{System.unique_integer([:positive])}"

    {:ok, _sup_pid} =
      MemSup.start_link(
        name: sup_name,
        store_name: store_name,
        data_dir: tmp_dir,
        repo: ExClaw.Repo
      )

    # Kill and wait for restart
    old_pid = GenServer.whereis(store_name)
    Process.exit(old_pid, :kill)
    Process.sleep(50)

    # Should still work after restart
    new_pid = GenServer.whereis(store_name)
    Ecto.Adapters.SQL.Sandbox.allow(ExClaw.Repo, self(), new_pid)

    assert {:ok, []} = ExClaw.Memory.Store.get_facts(store_name, "group1")
  end
end
