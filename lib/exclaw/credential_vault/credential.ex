defmodule ExClaw.CredentialVault.Credential do
  @moduledoc """
  Ecto schema for credential_vault_credentials table.
  Stores encrypted credential data with unencrypted metadata for querying.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_types ~w(oauth2 api_key bearer_token)

  schema "credential_vault_credentials" do
    field :name, :string
    field :type, :string
    field :encrypted_data, :binary
    field :scopes, {:array, :string}, default: []
    field :group_id, :string
    field :project_id, :string
    field :expires_at, :utc_datetime_usec
    field :last_refreshed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :name,
      :type,
      :encrypted_data,
      :scopes,
      :group_id,
      :project_id,
      :expires_at,
      :last_refreshed_at
    ])
    |> validate_required([:name, :type, :encrypted_data])
    |> validate_inclusion(:type, @valid_types)
    |> unique_constraint([:name, :group_id],
      name: :credential_vault_credentials_name_group_id_index
    )
  end

  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:encrypted_data, :scopes, :expires_at, :last_refreshed_at])
    |> validate_required([:encrypted_data])
  end
end
