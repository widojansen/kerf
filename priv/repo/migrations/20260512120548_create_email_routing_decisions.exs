defmodule Kerf.Repo.Migrations.CreateEmailRoutingDecisions do
  use Ecto.Migration

  def change do
    create table(:email_routing_decisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :email_triage_id, references(:email_triage, type: :uuid, on_delete: :delete_all), null: false
      add :rule_name, :string, null: false
      add :action_taken, :string, null: false
      add :routing_config_version, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:email_routing_decisions, [:email_triage_id])
    create index(:email_routing_decisions, [:action_taken])
    create index(:email_routing_decisions, [:inserted_at])
  end
end
