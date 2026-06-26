defmodule Mix.Tasks.Kerf.MigrateMonitoringStateTest do
  # Spec 4 Phase 1 — one-off state.json -> monitoring_state migration.
  # Synthetic fixtures only: NO real tenant data, NO real prod timestamps.
  # Epochs are synthetic 1_000_000_000.x values chosen for clean float behavior.
  use Kerf.DataCase, async: true

  import Ecto.Query

  alias Mix.Tasks.Kerf.MigrateMonitoringState, as: Migrate
  alias Kerf.ServiceHealth.State

  defp write_state_json(map) do
    path = Path.join(System.tmp_dir!(), "state_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(map))
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "epoch_to_datetime/1 — conversion (round, not truncate)" do
    test "1. preserves sub-second precision (round to microseconds)" do
      assert Migrate.epoch_to_datetime(1_000_000_000.5) == ~U[2001-09-09 01:46:40.500000Z]
    end

    test "2. boundary x.000001 keeps the microsecond" do
      assert Migrate.epoch_to_datetime(1_000_000_000.000001) == ~U[2001-09-09 01:46:40.000001Z]
    end

    test "3. boundary x.9999995 ROUNDS UP (trunc would silently give .999999)" do
      # round(.9999995s) -> next whole second; the spec forbids silent truncation.
      assert Migrate.epoch_to_datetime(1_000_000_000.9999995) == ~U[2001-09-09 01:46:41.000000Z]
    end

    test "4. nil / 0 / 0.0 -> nil" do
      assert Migrate.epoch_to_datetime(nil) == nil
      assert Migrate.epoch_to_datetime(0) == nil
      assert Migrate.epoch_to_datetime(0.0) == nil
    end
  end

  describe "migrate/1 — upsert" do
    test "5. last_alert_time absent in state.json -> nil in the row" do
      path =
        write_state_json(%{
          "last_alert_status" => "healthy",
          "consecutive_healthy" => 1,
          "consecutive_failures" => 0
        })

      assert {:ok, _} = Migrate.migrate(path)
      assert Repo.get_by!(State, target: "izi2connect").last_alert_time == nil
    end

    test "6. last_alert_time 0 -> nil in the row" do
      path =
        write_state_json(%{
          "last_alert_status" => "healthy",
          "last_alert_time" => 0,
          "consecutive_healthy" => 0,
          "consecutive_failures" => 0
        })

      assert {:ok, _} = Migrate.migrate(path)
      assert Repo.get_by!(State, target: "izi2connect").last_alert_time == nil
    end

    test "7. idempotent: running twice on the same fixture yields an identical row, no duplicate" do
      path =
        write_state_json(%{
          "last_alert_status" => "warning",
          "last_alert_time" => 1_000_000_000.5,
          "consecutive_healthy" => 42,
          "consecutive_failures" => 0
        })

      assert {:ok, _} = Migrate.migrate(path)
      row1 = Repo.get_by!(State, target: "izi2connect")

      assert {:ok, _} = Migrate.migrate(path)
      row2 = Repo.get_by!(State, target: "izi2connect")

      assert row1.last_alert_status == "warning"
      assert row1.last_alert_time == ~U[2001-09-09 01:46:40.500000Z]
      assert row1.consecutive_healthy == 42

      # Same meaningful fields both runs; exactly one izi2connect row (unique target).
      assert row2.last_alert_status == row1.last_alert_status
      assert row2.last_alert_time == row1.last_alert_time
      assert row2.consecutive_healthy == row1.consecutive_healthy

      count = Repo.aggregate(from(s in State, where: s.target == "izi2connect"), :count)
      assert count == 1
    end

    test "8. out-of-set last_alert_status -> clear error, no silent bad write" do
      path =
        write_state_json(%{
          "last_alert_status" => "bogus",
          "consecutive_healthy" => 0,
          "consecutive_failures" => 0
        })

      assert {:error, _} = Migrate.migrate(path)
      refute Repo.get_by!(State, target: "izi2connect").last_alert_status == "bogus"
    end
  end
end
