defmodule ExClaw.Repo.Migrations.CreateCredentialVaultLeaseLog do
  use Ecto.Migration

  def change do
    create table(:credential_vault_lease_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :lease_id, :string, null: false

      add :credential_id,
          references(:credential_vault_credentials, type: :uuid, on_delete: :delete_all),
          null: false

      add :agent_module, :string, null: false
      add :scopes, {:array, :string}, null: false
      add :group_id, :string
      add :issued_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      add :release_reason, :string
    end

    create index(:credential_vault_lease_log, [:credential_id])
    create index(:credential_vault_lease_log, [:issued_at])
  end
end
