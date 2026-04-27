defmodule Kerf.TelemetryTest do
  use ExUnit.Case, async: true

  alias Kerf.Telemetry
  alias Kerf.Telemetry.Logger

  @moduletag :telemetry

  setup do
    fallback_dir = Path.join(System.tmp_dir!(), "kerf_telem_api_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fallback_dir)

    name = :"telem_api_#{System.unique_integer([:positive])}"

    {:ok, _pid} = Logger.start_link(
      name: name,
      enabled: true,
      flush_interval_ms: 60_000,
      max_buffer_size: 1000,
      fallback_dir: fallback_dir,
      ch_opts: nil
    )

    on_exit(fn -> File.rm_rf!(fallback_dir) end)

    %{logger: name, fallback_dir: fallback_dir}
  end

  describe "emit/3" do
    test "returns :ok and buffers event", %{logger: name} do
      assert :ok = Telemetry.emit(name, :llm_call, %{model: "test", duration_ms: 42})
      assert Logger.buffer_size(name) == 1
    end

    test "returns :ok even when logger is dead" do
      dead_name = :"dead_logger_#{System.unique_integer([:positive])}"
      assert :ok = Telemetry.emit(dead_name, :test, %{x: 1})
    end

    test "returns :ok with empty data map", %{logger: name} do
      assert :ok = Telemetry.emit(name, :custom_event, %{})
      assert Logger.buffer_size(name) == 1
    end
  end

  describe "emit_sync/3" do
    test "synchronously buffers event", %{logger: name} do
      assert :ok = Telemetry.emit_sync(name, :security_check, %{module: "FileGuard"})
      assert Logger.buffer_size(name) == 1
    end

    test "returns :ok when logger is dead" do
      dead_name = :"dead_sync_#{System.unique_integer([:positive])}"
      assert :ok = Telemetry.emit_sync(dead_name, :test, %{})
    end
  end

  describe "span/4" do
    test "captures duration_ms and returns function result", %{logger: name} do
      result = Telemetry.span(name, :memory_operation, %{op_type: "save_fact"}, fn ->
        Process.sleep(10)
        {:ok, "saved"}
      end)

      assert result == {:ok, "saved"}

      # Event should be buffered with duration_ms
      :ok = Logger.flush(name)
    end

    test "captures timing even when function raises", %{logger: name} do
      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span(name, :test_op, %{}, fn ->
          raise "boom"
        end)
      end

      # Error event should still be buffered
      assert Logger.buffer_size(name) == 1
    end

    test "captures process memory delta", %{logger: name, fallback_dir: dir} do
      Telemetry.span(name, :memory_test, %{}, fn ->
        # Allocate some data to create a memory delta
        _data = :binary.copy("x", 10_000)
        :ok
      end)

      :ok = Logger.flush(name)

      files = Path.wildcard(Path.join(dir, "events_*.jsonl"))
      assert length(files) == 1
      [line] = files |> hd() |> File.read!() |> String.split("\n", trim: true)
      {:ok, event} = Jason.decode(line)

      assert Map.has_key?(event, "duration_ms")
      assert is_number(event["duration_ms"])
      assert Map.has_key?(event, "process_memory_bytes")
    end

    test "span returns :ok when logger is dead" do
      dead_name = :"dead_span_#{System.unique_integer([:positive])}"

      result = Telemetry.span(dead_name, :test, %{}, fn ->
        42
      end)

      assert result == 42
    end
  end
end
