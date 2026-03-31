defmodule ExClaw.CredentialVault.Policy do
  @moduledoc """
  Ecto schema for credential_vault_policies table.
  Maps (agent_module, credential_name, group_id) to allowed scopes and rate limits.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credential_vault_policies" do
    field :agent_module, :string
    field :credential_name, :string
    field :allowed_scopes, {:array, :string}, default: []
    field :group_id, :string
    field :max_lease_ttl, :integer, default: 300
    field :rate_limit_per_second, :integer, default: 10

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:agent_module, :credential_name, :allowed_scopes, :group_id, :max_lease_ttl, :rate_limit_per_second])
    |> validate_required([:agent_module, :credential_name, :allowed_scopes])
    |> unique_constraint([:agent_module, :credential_name, :group_id],
      name: :credential_vault_policies_agent_cred_group_index
    )
  end
end
