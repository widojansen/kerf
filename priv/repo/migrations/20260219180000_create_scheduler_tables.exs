defmodule ExClaw.Repo.Migrations.CreateSchedulerTables do
  use Ecto.Migration

  def change do
    create table(:scheduled_tasks) do
      add :group_id, :string, null: false
      add :prompt, :text, null: false
      add :schedule_type, :string, null: false
      add :schedule_value, :string, null: false, default: ""
      add :context_mode, :string, null: false, default: "isolated"
      add :next_run, :utc_datetime
      add :last_run, :utc_datetime
      add :last_result, :text
      add :status, :string, null: false, default: "active"

      timestamps()
    end

    create index(:scheduled_tasks, [:status, :next_run])
    create index(:scheduled_tasks, [:group_id])

    create table(:task_run_logs) do
      add :task_id, references(:scheduled_tasks, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime, null: false
      add :duration_ms, :integer, null: false
      add :status, :string, null: false
      add :result, :text
      add :error, :text

      timestamps()
    end

    create index(:task_run_logs, [:task_id, :started_at])
  end
end
