defmodule ExClaw.Telemetry.LoggerTest do
  use ExUnit.Case, async: true

  alias ExClaw.Telemetry.Logger

  @moduletag :telemetry

  setup do
    fallback_dir = Path.join(System.tmp_dir!(), "exclaw_telemetry_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fallback_dir)

    opts = [
      name: :"logger_test_#{System.unique_integer([:positive])}",
      enabled: true,
      flush_interval_ms: 60_000,
      max_buffer_size: 100,
      fallback_dir: fallback_dir,
      ch_opts: nil
    ]

    {:ok, pid} = Logger.start_link(opts)

    on_exit(fn ->
      File.rm_rf!(fallback_dir)
    end)

    %{pid: pid, name: opts[:name], fallback_dir: fallback_dir}
  end

  describe "buffering" do
    test "buffered events increase buffer_size", %{name: name} do
      assert Logger.buffer_size(name) == 0

      Logger.emit_event(name, :llm_call, %{model: "test"})
      assert Logger.buffer_size(name) == 1

      Logger.emit_event(name, :llm_call, %{model: "test2"})
      assert Logger.buffer_size(name) == 2
    end

    test "flush clears the buffer and writes JSONL", %{name: name, fallback_dir: dir} do
      Logger.emit_event(name, :llm_call, %{model: "test", duration_ms: 42})
      Logger.emit_event(name, :security_check, %{module: "FileGuard"})
      assert Logger.buffer_size(name) == 2

      :ok = Logger.flush(name)
      assert Logger.buffer_size(name) == 0

      # JSONL file should exist with 2 lines
      files = Path.wildcard(Path.join(dir, "events_*.jsonl"))
      assert length(files) == 1

      lines =
        files |> hd() |> File.read!() |> String.split("\n", trim: true)

      assert length(lines) == 2

      # Each line is valid JSON
      for line <- lines do
        assert {:ok, _} = Jason.decode(line)
      end
    end

    test "flush with empty buffer is a no-op", %{name: name, fallback_dir: dir} do
      :ok = Logger.flush(name)
      assert Logger.buffer_size(name) == 0

      files = Path.wildcard(Path.join(dir, "events_*.jsonl"))
      assert files == []
    end

    test "auto-flush when buffer hits max_buffer_size" do
      fallback_dir = Path.join(System.tmp_dir!(), "exclaw_telem_auto_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fallback_dir)

      name = :"auto_flush_test_#{System.unique_integer([:positive])}"

      {:ok, _pid} = Logger.start_link(
        name: name,
        enabled: true,
        flush_interval_ms: 60_000,
        max_buffer_size: 3,
        fallback_dir: fallback_dir,
        ch_opts: nil
      )

      # Send 3 events — should trigger auto-flush
      Logger.emit_event(name, :a, %{i: 1})
      Logger.emit_event(name, :b, %{i: 2})
      Logger.emit_event(name, :c, %{i: 3})

      # Give cast time to process
      Process.sleep(50)

      assert Logger.buffer_size(name) == 0

      files = Path.wildcard(Path.join(fallback_dir, "events_*.jsonl"))
      assert length(files) == 1

      lines = files |> hd() |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 3

      File.rm_rf!(fallback_dir)
    end
  end

  describe "JSONL fallback" do
    test "events written to date-named file", %{name: name, fallback_dir: dir} do
      Logger.emit_event(name, :tool_execution, %{tool_name: "shell_exec", duration_ms: 10})
      :ok = Logger.flush(name)

      date = Date.utc_today() |> Date.to_iso8601()
      expected_file = Path.join(dir, "events_#{date}.jsonl")
      assert File.exists?(expected_file)
    end

    test "JSONL contains correct event structure", %{name: name, fallback_dir: dir} do
      Logger.emit_event(name, :llm_call, %{model: "claude", duration_ms: 100, input_tokens: 50})
      :ok = Logger.flush(name)

      files = Path.wildcard(Path.join(dir, "events_*.jsonl"))
      [line] = files |> hd() |> File.read!() |> String.split("\n", trim: true)
      {:ok, event} = Jason.decode(line)

      assert event["event_type"] == "llm_call"
      assert event["model"] == "claude"
      assert event["duration_ms"] == 100
      assert event["input_tokens"] == 50
      assert Map.has_key?(event, "timestamp")
    end

    test "fallback survives unwritable directory", %{name: _name} do
      bad_dir = "/nonexistent/path/that/does/not/exist"
      bad_name = :"bad_dir_test_#{System.unique_integer([:positive])}"

      {:ok, _pid} = Logger.start_link(
        name: bad_name,
        enabled: true,
        flush_interval_ms: 60_000,
        max_buffer_size: 100,
        fallback_dir: bad_dir,
        ch_opts: nil
      )

      Logger.emit_event(bad_name, :test, %{x: 1})
      # Should not crash
      :ok = Logger.flush(bad_name)
    end
  end

  describe "enabled flag" do
    test "disabled logger discards events" do
      name = :"disabled_test_#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), "exclaw_disabled_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      {:ok, _pid} = Logger.start_link(
        name: name,
        enabled: false,
        flush_interval_ms: 60_000,
        max_buffer_size: 100,
        fallback_dir: dir,
        ch_opts: nil
      )

      Logger.emit_event(name, :llm_call, %{model: "test"})
      Process.sleep(20)
      assert Logger.buffer_size(name) == 0

      :ok = Logger.flush(name)
      files = Path.wildcard(Path.join(dir, "events_*.jsonl"))
      assert files == []

      File.rm_rf!(dir)
    end
  end

  describe "stats" do
    test "get_stats returns counters", %{name: name} do
      Logger.emit_event(name, :llm_call, %{})
      Logger.emit_event(name, :llm_call, %{})
      Logger.emit_event(name, :security_check, %{})

      stats = Logger.get_stats(name)
      assert stats.events_received == 3
      assert stats.buffer_size == 3
    end

    test "stats update after flush", %{name: name} do
      Logger.emit_event(name, :test, %{})
      :ok = Logger.flush(name)

      stats = Logger.get_stats(name)
      assert stats.events_received == 1
      assert stats.flushes == 1
      assert stats.buffer_size == 0
    end
  end

  describe "periodic flush" do
    test "timer fires and flushes buffer" do
      dir = Path.join(System.tmp_dir!(), "exclaw_timer_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      name = :"timer_test_#{System.unique_integer([:positive])}"

      {:ok, _pid} = Logger.start_link(
        name: name,
        enabled: true,
        flush_interval_ms: 50,
        max_buffer_size: 1000,
        fallback_dir: dir,
        ch_opts: nil
      )

      Logger.emit_event(name, :test, %{i: 1})
      assert Logger.buffer_size(name) == 1

      # Wait for periodic flush
      Process.sleep(100)

      assert Logger.buffer_size(name) == 0

      files = Path.wildcard(Path.join(dir, "events_*.jsonl"))
      assert length(files) == 1

      File.rm_rf!(dir)
    end
  end
end
