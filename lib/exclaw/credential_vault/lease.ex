defmodule Kerf.CredentialVault.Lease do
  @moduledoc """
  Struct representing an active credential lease.
  """

  @enforce_keys [:id, :credential_id, :credential_name, :agent_module, :scopes, :expires_at, :issued_at]
  defstruct [
    :id,
    :credential_id,
    :credential_name,
    :agent_module,
    :agent_pid,
    :monitor_ref,
    :scopes,
    :access_token,
    :expires_at,
    :issued_at,
    :group_id,
    request_count: 0,
    revoked?: false
  ]
end
