defmodule ExClaw.CredentialVault.Backend do
  @moduledoc """
  Behaviour for credential storage backends.
  """

  @type credential_id :: String.t()
  @type credential_name :: String.t()
  @type credential_type :: :oauth2 | :api_key | :bearer_token
  @type encryption_key :: binary()

  @callback store(credential_name, credential_type, map(), encryption_key, keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback get(credential_id, encryption_key) ::
              {:ok, map()} | {:error, :not_found | :decryption_failed}

  @callback update(credential_id, map(), encryption_key, keyword()) ::
              :ok | {:error, :not_found | term()}

  @callback delete(credential_id) :: :ok | {:error, :not_found}

  @callback list(keyword()) :: [map()]
end
