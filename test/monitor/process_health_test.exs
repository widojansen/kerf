defmodule Kerf.Monitor.ProcessHealthTest do
  use ExUnit.Case, async: true

  alias Kerf.Monitor.ProcessHealth

  # Helper: start ProcessHealth with a custom watched list and fast tick
  defp start_health(opts \\ []) do
    name = :"health_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      watched: Keyword.get(opts, :watched, []),
      interval_ms: Keyword.get(opts, :interval_ms, :manual),
      queue_high_threshold: Keyword.get(opts, :queue_high_threshold, 100),
      memory_high_threshold_mb: Keyword.get(opts, :memory_high_threshold_mb, 256)
    ]

    {:ok, pid} = ProcessHealth.start_link(defaults)
    {pid, name}
  end

  # Helper: attach a telemetry handler that sends events to the test process
  defp attach_handler(event_name) do
    ref = make_ref()
    test_pid = self()

    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach(handler_id, event_name, fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "status/1" do
    test "returns :ok for all watched processes that are alive" do
      # Watch the current test process (definitely alive)
      Process.register(self(), :"test_process_#{System.unique_integer([:positive])}")
      registered_name = Process.info(self())[:registered_name]

      {_pid, name} = start_health(watched: [registered_name])
      result = ProcessHealth.status(name)

      assert result[registered_name] == :ok
    end

    test "returns :down for missing processes" do
      {_pid, name} = start_health(watched: [:nonexistent_process_xyz])
      result = ProcessHealth.status(name)

      assert result[:nonexistent_process_xyz] == :down
    end

    test "returns empty map when nothing is watched" do
      {_pid, name} = start_health(watched: [])
      assert ProcessHealth.status(name) == %{}
    end
  end

  describe "add_watch/2 and remove_watch/2" do
    test "dynamically adds a process to the watch list" do
      {_pid, name} = start_health(watched: [])

      assert ProcessHealth.status(name) == %{}
      :ok = ProcessHealth.add_watch(name, :nonexistent_abc)
      assert %{nonexistent_abc: :down} = ProcessHealth.status(name)
    end

    test "dynamically removes a process from the watch list" do
      {_pid, name} = start_health(watched: [:some_process])

      :ok = ProcessHealth.remove_watch(name, :some_process)
      assert ProcessHealth.status(name) == %{}
    end
  end

  describe "telemetry events" do
    test "emits :process_down when a watched process is missing" do
      attach_handler([:exclaw, :monitor, :process_down])

      {_pid, name} = start_health(watched: [:missing_genserver_xyz])
      ProcessHealth.check_now(name)

      assert_receive {:telemetry, [:exclaw, :monitor, :process_down], %{}, %{name: :missing_genserver_xyz}},
                     1000
    end

    @tag capture_log: true
    test "emits :queue_high when message queue exceeds threshold" do
      attach_handler([:exclaw, :monitor, :queue_high])

      # Start a GenServer that accumulates messages without processing them
      {:ok, blocker} = Agent.start_link(fn -> :ok end)
      Process.register(blocker, :test_blocker)

      # Flood its mailbox
      for _ <- 1..150, do: send(blocker, :junk)

      {_pid, name} = start_health(watched: [:test_blocker], queue_high_threshold: 50)
      ProcessHealth.check_now(name)

      assert_receive {:telemetry, [:exclaw, :monitor, :queue_high], %{queue_len: queue_len},
                       %{name: :test_blocker, threshold: 50}},
                     1000

      assert queue_len >= 50
      Agent.stop(blocker)
    end

    test "emits :health_check on every tick with summary" do
      attach_handler([:exclaw, :monitor, :health_check])

      {_pid, name} = start_health(watched: [])
      ProcessHealth.check_now(name)

      assert_receive {:telemetry, [:exclaw, :monitor, :health_check], %{duration_us: _},
                       %{process_count: 0, all_healthy: true}},
                     1000
    end

    test "health_check reports all_healthy: false when a process is down" do
      attach_handler([:exclaw, :monitor, :health_check])

      {_pid, name} = start_health(watched: [:definitely_not_running])
      ProcessHealth.check_now(name)

      assert_receive {:telemetry, [:exclaw, :monitor, :health_check], _,
                       %{process_count: 1, all_healthy: false}},
                     1000
    end

    test "does not emit :process_down for alive processes" do
      attach_handler([:exclaw, :monitor, :process_down])

      proc_name = :"alive_proc_#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.start_link(fn -> :ok end, name: proc_name)

      {_pid, name} = start_health(watched: [proc_name])
      ProcessHealth.check_now(name)

      refute_receive {:telemetry, [:exclaw, :monitor, :process_down], _, _}, 200
    end
  end

  describe "periodic check" do
    test "runs checks on the configured interval" do
      attach_handler([:exclaw, :monitor, :health_check])

      {_pid, _name} = start_health(watched: [], interval_ms: 50)

      # Should fire at least twice in 150ms
      assert_receive {:telemetry, [:exclaw, :monitor, :health_check], _, _}, 200
      assert_receive {:telemetry, [:exclaw, :monitor, :health_check], _, _}, 200
    end
  end
end
