defmodule Kerf.Repo.Migrations.CreateCredentialVaultCredentials do
  use Ecto.Migration

  def change do
    create table(:credential_vault_credentials, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :type, :string, null: false
      add :encrypted_data, :binary, null: false
      add :scopes, {:array, :string}, default: []
      add :group_id, :string
      add :project_id, :string
      add :expires_at, :utc_datetime_usec
      add :last_refreshed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_vault_credentials, [:name, :group_id],
             name: :credential_vault_credentials_name_group_id_index
           )

    create index(:credential_vault_credentials, [:group_id])
    create index(:credential_vault_credentials, [:type])

    create index(:credential_vault_credentials, [:expires_at],
             where: "expires_at IS NOT NULL",
             name: :credential_vault_credentials_expires_at_index
           )
  end
end
