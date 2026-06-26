defmodule Kerf.Repo.Migrations.CreateMonitoringState do
  use Ecto.Migration

  # Spec 2 — monitoring_state state-machine table (SPEC_02_ALERT_STATE_MACHINE.md).
  # Single row in practice (target "izi2connect"), but unique-on-target so a future
  # multi-target version is a non-breaking addition. Seeds Python load_state defaults;
  # the live state.json import (consecutive_healthy: 18896 etc.) is Spec 4, NOT here.
  def change do
    create table(:monitoring_state) do
      add :target, :string, null: false
      add :last_alert_status, :string
      add :last_alert_time, :utc_datetime_usec
      add :consecutive_healthy, :integer, null: false, default: 0
      add :consecutive_failures, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:monitoring_state, [:target])

    execute(
      """
      INSERT INTO monitoring_state
        (target, last_alert_status, last_alert_time, consecutive_healthy, consecutive_failures, inserted_at, updated_at)
      VALUES
        ('izi2connect', 'healthy', NULL, 0, 0, NOW(), NOW())
      """,
      "DELETE FROM monitoring_state WHERE target = 'izi2connect'"
    )
  end
end
