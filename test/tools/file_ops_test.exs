defmodule ExClaw.Tools.FileOpsTest do
  use ExUnit.Case, async: true

  alias ExClaw.Tools.FileOps

  setup do
    workspaces_dir = System.tmp_dir!() |> Path.join("exclaw_fileops_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(workspaces_dir)
    group_dir = Path.join(workspaces_dir, "test_group")
    File.mkdir_p!(group_dir)

    on_exit(fn -> File.rm_rf(workspaces_dir) end)
    %{workspaces_dir: workspaces_dir, group_dir: group_dir}
  end

  describe "read/2" do
    test "reads a file from the group workspace", %{workspaces_dir: dir, group_dir: group_dir} do
      File.write!(Path.join(group_dir, "hello.txt"), "hello world")

      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:ok, "hello world"} = FileOps.read(%{"path" => "hello.txt"}, opts)
    end

    test "reads files in subdirectories", %{workspaces_dir: dir, group_dir: group_dir} do
      sub = Path.join(group_dir, "sub")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "nested.txt"), "nested content")

      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:ok, "nested content"} = FileOps.read(%{"path" => "sub/nested.txt"}, opts)
    end

    test "returns error for non-existent file", %{workspaces_dir: dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:error, reason} = FileOps.read(%{"path" => "missing.txt"}, opts)
      assert reason =~ "not found" or reason =~ "enoent"
    end

    test "blocks path traversal via ..", %{workspaces_dir: dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:error, reason} = FileOps.read(%{"path" => "../../../etc/passwd"}, opts)
      assert reason =~ "denied" or reason =~ "traversal" or reason =~ "outside"
    end

    test "blocks absolute paths outside workspace", %{workspaces_dir: dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:error, _reason} = FileOps.read(%{"path" => "/etc/passwd"}, opts)
    end

    test "returns error when path key is missing" do
      opts = [workspaces_dir: "/tmp", group_id: "test_group"]
      assert {:error, reason} = FileOps.read(%{}, opts)
      assert reason =~ "path" or reason =~ "missing"
    end
  end

  describe "write/2" do
    test "writes a file to the group workspace", %{workspaces_dir: dir, group_dir: group_dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:ok, _msg} = FileOps.write(%{"path" => "out.txt", "content" => "data"}, opts)
      assert File.read!(Path.join(group_dir, "out.txt")) == "data"
    end

    test "creates intermediate directories", %{workspaces_dir: dir, group_dir: group_dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:ok, _msg} = FileOps.write(%{"path" => "a/b/c.txt", "content" => "deep"}, opts)
      assert File.read!(Path.join(group_dir, "a/b/c.txt")) == "deep"
    end

    test "blocks path traversal via ..", %{workspaces_dir: dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:error, reason} = FileOps.write(%{"path" => "../../escape.txt", "content" => "bad"}, opts)
      assert reason =~ "denied" or reason =~ "traversal" or reason =~ "outside"
    end

    test "returns error when path key is missing" do
      opts = [workspaces_dir: "/tmp", group_id: "test_group"]
      assert {:error, _reason} = FileOps.write(%{"content" => "data"}, opts)
    end

    test "returns error when content key is missing", %{workspaces_dir: dir} do
      opts = [workspaces_dir: dir, group_id: "test_group"]
      assert {:error, _reason} = FileOps.write(%{"path" => "out.txt"}, opts)
    end
  end
end
