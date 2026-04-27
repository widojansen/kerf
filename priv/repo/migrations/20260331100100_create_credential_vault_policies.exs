defmodule Kerf.Repo.Migrations.CreateCredentialVaultPolicies do
  use Ecto.Migration

  def change do
    create table(:credential_vault_policies, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_module, :string, null: false
      add :credential_name, :string, null: false
      add :allowed_scopes, {:array, :string}, null: false
      add :group_id, :string
      add :max_lease_ttl, :integer, default: 300
      add :rate_limit_per_second, :integer, default: 10

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:credential_vault_policies, [:agent_module, :credential_name, :group_id],
             name: :credential_vault_policies_agent_cred_group_index
           )
  end
end
