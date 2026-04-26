defmodule Kerf.Scheduler.SchemaTest do
  use ExUnit.Case, async: true

  alias Kerf.Scheduler.ScheduledTask
  alias Kerf.Scheduler.TaskRunLog

  describe "ScheduledTask changeset" do
    test "valid cron changeset" do
      attrs = %{
        group_id: "test-group",
        prompt: "What's the weather?",
        schedule_type: "cron",
        schedule_value: "0 7 * * *"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      assert changeset.valid?
    end

    test "valid interval changeset" do
      attrs = %{
        group_id: "test-group",
        prompt: "Check status",
        schedule_type: "interval",
        schedule_value: "300000"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      assert changeset.valid?
    end

    test "valid at changeset" do
      attrs = %{
        group_id: "test-group",
        prompt: "Send reminder",
        schedule_type: "at",
        schedule_value: "2026-03-01T09:00:00Z"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      assert changeset.valid?
    end

    test "valid once changeset" do
      attrs = %{
        group_id: "test-group",
        prompt: "One-shot task",
        schedule_type: "once",
        schedule_value: ""
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      assert changeset.valid?
    end

    test "rejects invalid cron expression" do
      attrs = %{
        group_id: "test-group",
        prompt: "Bad cron",
        schedule_type: "cron",
        schedule_value: "not a cron"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      refute changeset.valid?
      assert {"is not a valid cron expression", _} = changeset.errors[:schedule_value]
    end

    test "rejects non-numeric interval" do
      attrs = %{
        group_id: "test-group",
        prompt: "Bad interval",
        schedule_type: "interval",
        schedule_value: "abc"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      refute changeset.valid?
      assert {"must be a positive integer (milliseconds)", _} = changeset.errors[:schedule_value]
    end

    test "rejects invalid ISO-8601 for at type" do
      attrs = %{
        group_id: "test-group",
        prompt: "Bad at",
        schedule_type: "at",
        schedule_value: "not-a-date"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      refute changeset.valid?
      assert {"is not a valid ISO-8601 datetime", _} = changeset.errors[:schedule_value]
    end

    test "validates status inclusion" do
      attrs = %{
        group_id: "test-group",
        prompt: "Test",
        schedule_type: "once",
        schedule_value: "",
        status: "invalid"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:status]
    end

    test "validates context_mode inclusion" do
      attrs = %{
        group_id: "test-group",
        prompt: "Test",
        schedule_type: "once",
        schedule_value: "",
        context_mode: "invalid"
      }

      changeset = ScheduledTask.changeset(%ScheduledTask{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:context_mode]
    end
  end

  describe "TaskRunLog changeset" do
    test "valid changeset" do
      attrs = %{
        task_id: 1,
        started_at: ~U[2026-03-01 09:00:00Z],
        duration_ms: 1500,
        status: "success",
        result: "Done"
      }

      changeset = TaskRunLog.changeset(%TaskRunLog{}, attrs)
      assert changeset.valid?
    end

    test "rejects negative duration" do
      attrs = %{
        task_id: 1,
        started_at: ~U[2026-03-01 09:00:00Z],
        duration_ms: -100,
        status: "success"
      }

      changeset = TaskRunLog.changeset(%TaskRunLog{}, attrs)
      refute changeset.valid?
      assert {"must be greater than or equal to %{number}", _} = changeset.errors[:duration_ms]
    end

    test "validates status inclusion" do
      attrs = %{
        task_id: 1,
        started_at: ~U[2026-03-01 09:00:00Z],
        duration_ms: 100,
        status: "invalid"
      }

      changeset = TaskRunLog.changeset(%TaskRunLog{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:status]
    end
  end
end
