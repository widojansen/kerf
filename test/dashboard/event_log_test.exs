defmodule ExClaw.Dashboard.EventLogTest do
  use ExUnit.Case, async: true

  alias ExClaw.Dashboard.EventLog

  setup do
    suffix = System.unique_integer([:positive])
    table_name = :"event_log_#{suffix}"
    name = :"event_log_proc_#{suffix}"

    {:ok, _pid} =
      EventLog.start_link(
        name: name,
        table: table_name,
        max_size: 10,
        pubsub: nil
      )

    %{log: name, table: table_name}
  end

  describe "log/3 and recent/3" do
    test "logs and retrieves events", %{log: log, table: table} do
      EventLog.log_sync(log, :security_denial, %{reason: "blocked"})
      EventLog.log_sync(log, :security_denial, %{reason: "also blocked"})

      events = EventLog.recent_from(table, :security_denial)
      assert length(events) == 2
    end

    test "returns events in reverse chronological order", %{log: log, table: table} do
      EventLog.log_sync(log, :llm_call, %{model: "first"})
      EventLog.log_sync(log, :llm_call, %{model: "second"})

      [newest, oldest] = EventLog.recent_from(table, :llm_call)
      assert newest.event.model == "second"
      assert oldest.event.model == "first"
    end

    test "filters by category", %{log: log, table: table} do
      EventLog.log_sync(log, :security_denial, %{reason: "blocked"})
      EventLog.log_sync(log, :llm_call, %{model: "test"})

      denials = EventLog.recent_from(table, :security_denial)
      assert length(denials) == 1
      assert hd(denials).category == :security_denial

      calls = EventLog.recent_from(table, :llm_call)
      assert length(calls) == 1
      assert hd(calls).category == :llm_call
    end

    test "respects limit parameter", %{log: log, table: table} do
      for i <- 1..5, do: EventLog.log_sync(log, :llm_call, %{n: i})

      events = EventLog.recent_from(table, :llm_call, 3)
      assert length(events) == 3
    end

    test "returns empty list for unknown category", %{table: table} do
      events = EventLog.recent_from(table, :nonexistent)
      assert events == []
    end
  end

  describe "ring buffer eviction" do
    test "evicts oldest entries when max_size exceeded", %{log: log, table: table} do
      # max_size is 10
      for i <- 1..15, do: EventLog.log_sync(log, :llm_call, %{n: i})

      events = EventLog.recent_from(table, :llm_call, 100)
      assert length(events) == 10

      # Should have the most recent 10 entries (6-15)
      numbers = Enum.map(events, & &1.event.n)
      assert 6 in numbers
      assert 15 in numbers
      refute 1 in numbers
    end
  end

  describe "all_recent/2" do
    test "returns events across all categories", %{log: log, table: table} do
      EventLog.log_sync(log, :security_denial, %{reason: "blocked"})
      EventLog.log_sync(log, :llm_call, %{model: "test"})
      EventLog.log_sync(log, :llm_error, %{error: "timeout"})

      events = EventLog.all_recent_from(table)
      assert length(events) == 3
    end
  end

  describe "log/3 with struct conversion" do
    test "event maps are accessible as structs", %{log: log, table: table} do
      EventLog.log_sync(log, :security_denial, %{module: "FileGuard", reason: "traversal"})

      [event_entry] = EventLog.recent_from(table, :security_denial)
      assert event_entry.event.module == "FileGuard"
      assert event_entry.event.reason == "traversal"
      assert is_integer(event_entry.seq_id)
      assert %DateTime{} = event_entry.timestamp
    end
  end

  describe "concurrent access" do
    test "handles concurrent writes without errors", %{log: log, table: table} do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            EventLog.log_sync(log, :llm_call, %{n: i})
          end)
        end

      Task.await_many(tasks)

      events = EventLog.recent_from(table, :llm_call, 100)
      assert length(events) == 10  # max_size is 10
    end
  end

  describe "start_link/1" do
    test "starts with default config" do
      suffix = System.unique_integer([:positive])

      {:ok, pid} =
        EventLog.start_link(
          name: :"default_log_#{suffix}",
          table: :"default_table_#{suffix}",
          pubsub: nil
        )

      assert Process.alive?(pid)
    end
  end
end
