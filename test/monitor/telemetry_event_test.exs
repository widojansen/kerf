defmodule ExClaw.Monitor.TelemetryEventTest do
  use ExClaw.DataCase, async: true

  alias ExClaw.Monitor.TelemetryEvent

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "valid with required fields" do
      attrs = %{
        event_name: "llm.call.stop",
        measurements: %{"latency_ms" => 1200},
        metadata: %{"model" => "qwen3-32b"}
      }

      changeset = TelemetryEvent.changeset(%TelemetryEvent{}, attrs)
      assert changeset.valid?
    end

    test "requires event_name" do
      changeset =
        TelemetryEvent.changeset(%TelemetryEvent{}, %{
          measurements: %{},
          metadata: %{}
        })

      refute changeset.valid?
      assert %{event_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "defaults measurements and metadata to empty maps" do
      changeset =
        TelemetryEvent.changeset(%TelemetryEvent{}, %{event_name: "test.event"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :measurements) == %{}
      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end
  end

  describe "insert" do
    test "persists to database with JSONB columns" do
      attrs = %{
        event_name: "monitor.process_down",
        measurements: %{"queue_len" => 150},
        metadata: %{"name" => "ExClaw.ModelRouter", "threshold" => 100}
      }

      assert {:ok, event} =
               %TelemetryEvent{}
               |> TelemetryEvent.changeset(attrs)
               |> ExClaw.Repo.insert()

      assert event.id
      assert event.event_name == "monitor.process_down"
      assert event.measurements == %{"queue_len" => 150}
      assert event.metadata == %{"name" => "ExClaw.ModelRouter", "threshold" => 100}
      assert event.inserted_at
    end

    test "queryable by event_name" do
      for name <- ["llm.call.stop", "llm.call.stop", "monitor.health_check"] do
        %TelemetryEvent{}
        |> TelemetryEvent.changeset(%{event_name: name})
        |> ExClaw.Repo.insert!()
      end

      import Ecto.Query

      count =
        from(e in TelemetryEvent, where: e.event_name == "llm.call.stop")
        |> ExClaw.Repo.aggregate(:count)

      assert count == 2
    end
  end
end
