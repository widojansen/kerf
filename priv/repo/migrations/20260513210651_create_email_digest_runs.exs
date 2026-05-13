defmodule Kerf.Repo.Migrations.CreateEmailDigestRuns do
  use Ecto.Migration

  def change do
    create table(:email_digest_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :sent_at, :utc_datetime_usec, null: false
      add :decision_count, :integer, null: false, default: 0
      add :status, :string, null: false
      add :error, :text
      add :window_start, :utc_datetime_usec, null: true
      add :window_end, :utc_datetime_usec, null: true

      # Insert-only audit log: no updated_at (matches kb_feedback +
      # email_routing_decisions audit-log convention).
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:email_digest_runs, [:status])
    create index(:email_digest_runs, [:sent_at])
  end
end
