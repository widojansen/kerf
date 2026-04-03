defmodule ExClaw.Repo.Migrations.CreateTelemetryEvents do
  use Ecto.Migration

  def change do
    create table(:telemetry_events) do
      add :event_name, :string, null: false
      add :measurements, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create index(:telemetry_events, [:event_name])
    create index(:telemetry_events, [:inserted_at])
  end
end
