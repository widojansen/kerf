defmodule Kerf.Security.FileGuardTest do
  use ExUnit.Case, async: true

  alias Kerf.Security.FileGuard

  describe "check/2 with file_read tool" do
    test "allows reading files within /workspace" do
      assert :ok = FileGuard.check("file_read", %{path: "/workspace/notes.txt"})
    end

    test "allows reading nested workspace paths" do
      assert :ok = FileGuard.check("file_read", %{path: "/workspace/project/src/main.ex"})
    end

    test "allows relative paths within workspace" do
      assert :ok = FileGuard.check("file_read", %{path: "notes.txt"})
    end

    test "blocks path traversal with .." do
      assert {:denied, reason} = FileGuard.check("file_read", %{path: "/workspace/../etc/passwd"})
      assert reason =~ "traversal"
    end

    test "blocks double-encoded path traversal" do
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/workspace/..%2F..%2Fetc/passwd"})
    end

    test "blocks absolute paths outside workspace" do
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/etc/passwd"})
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/etc/shadow"})
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/root/.ssh/id_rsa"})
    end

    test "blocks access to sensitive dotfiles" do
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/workspace/.env"})
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/workspace/.ssh/id_rsa"})
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/workspace/.aws/credentials"})
    end

    test "blocks access to home directory secrets" do
      assert {:denied, _} = FileGuard.check("file_read", %{path: "~/.ssh/id_rsa"})
      assert {:denied, _} = FileGuard.check("file_read", %{path: "~/.gnupg/private-keys-v1.d/"})
    end

    test "blocks null byte injection" do
      assert {:denied, _} = FileGuard.check("file_read", %{path: "/workspace/safe.txt" <> <<0>> <> "/../etc/passwd"})
    end
  end

  describe "check/2 with file_write tool" do
    test "allows writing files within /workspace" do
      assert :ok = FileGuard.check("file_write", %{path: "/workspace/output.txt", content: "hello"})
    end

    test "blocks writing outside workspace" do
      assert {:denied, _} = FileGuard.check("file_write", %{path: "/tmp/evil.sh", content: "rm -rf /"})
    end

    test "blocks writing to sensitive files" do
      assert {:denied, _} = FileGuard.check("file_write", %{path: "/workspace/.env", content: "SECRET=bad"})
    end

    test "blocks overwriting system files via traversal" do
      assert {:denied, _} = FileGuard.check("file_write", %{path: "/workspace/../../etc/crontab", content: "* * * * * evil"})
    end
  end

  describe "check/2 with non-file tools" do
    test "passes through non-file tools unchanged" do
      assert :ok = FileGuard.check("web_search", %{query: "elixir otp"})
      assert :ok = FileGuard.check("shell_exec", %{command: "ls"})
    end
  end
end
