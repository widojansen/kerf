defmodule Kerf.CredentialVault.Backend.LocalEncrypted do
  @moduledoc """
  PostgreSQL-backed credential storage with AES-256-GCM encryption at rest.

  Uses Erlang's `:crypto` module directly for encryption. The encryption key
  is derived from `SECRET_KEY_BASE` at boot time.
  """

  @behaviour Kerf.CredentialVault.Backend

  alias Kerf.CredentialVault.Credential
  alias Kerf.Repo
  import Ecto.Query

  @aad "exclaw_credential_vault_v1"

  # --- Public API ---

  @impl true
  def store(name, type, data, encryption_key, opts \\ []) do
    encrypted = encrypt(Jason.encode!(data), encryption_key)

    attrs = %{
      name: name,
      type: to_string(type),
      encrypted_data: encrypted,
      scopes: extract_scopes(data),
      group_id: Keyword.get(opts, :group_id),
      project_id: Keyword.get(opts, :project_id),
      expires_at: extract_expires_at(data)
    }

    %Credential{}
    |> Credential.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, to_metadata(record)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @impl true
  def get(credential_id, encryption_key) do
    case Repo.get(Credential, credential_id) do
      nil ->
        {:error, :not_found}

      record ->
        case decrypt(record.encrypted_data, encryption_key) do
          {:ok, plaintext} ->
            {:ok, to_decrypted(record, Jason.decode!(plaintext))}

          :error ->
            {:error, :decryption_failed}
        end
    end
  end

  def get_by_name(name, encryption_key) do
    case Repo.one(from(c in Credential, where: c.name == ^name)) do
      nil ->
        {:error, :not_found}

      record ->
        case decrypt(record.encrypted_data, encryption_key) do
          {:ok, plaintext} ->
            {:ok, to_decrypted(record, Jason.decode!(plaintext))}

          :error ->
            {:error, :decryption_failed}
        end
    end
  end

  @impl true
  def update(credential_id, data, encryption_key, opts \\ []) do
    case Repo.get(Credential, credential_id) do
      nil ->
        {:error, :not_found}

      record ->
        encrypted = encrypt(Jason.encode!(data), encryption_key)

        update_attrs =
          %{encrypted_data: encrypted}
          |> maybe_put(:expires_at, Keyword.get(opts, :expires_at))
          |> maybe_put(:last_refreshed_at, Keyword.get(opts, :last_refreshed_at))
          |> maybe_put(:scopes, extract_scopes(data))

        record
        |> Credential.update_changeset(update_attrs)
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def delete(credential_id) do
    case Repo.get(Credential, credential_id) do
      nil -> {:error, :not_found}
      record -> Repo.delete(record) |> then(fn {:ok, _} -> :ok end)
    end
  end

  @impl true
  def list(opts \\ []) do
    query = from(c in Credential, order_by: [asc: c.name])

    query =
      case Keyword.get(opts, :group_id) do
        nil -> query
        gid -> from(c in query, where: c.group_id == ^gid)
      end

    query =
      case Keyword.get(opts, :type) do
        nil -> query
        type -> from(c in query, where: c.type == ^to_string(type))
      end

    Repo.all(query)
    |> Enum.map(&to_metadata/1)
  end

  # --- Encryption ---

  defp encrypt(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  defp decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, key) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  rescue
    _ -> :error
  end

  defp decrypt(_invalid, _key), do: :error

  # --- Helpers ---

  defp to_metadata(%Credential{} = c) do
    %{
      id: c.id,
      name: c.name,
      type: String.to_existing_atom(c.type),
      scopes: c.scopes || [],
      group_id: c.group_id,
      project_id: c.project_id,
      expires_at: c.expires_at,
      last_refreshed_at: c.last_refreshed_at,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp to_decrypted(%Credential{} = c, decrypted_data) do
    c
    |> to_metadata()
    |> Map.put(:decrypted_data, decrypted_data)
  end

  defp extract_scopes(%{scopes: scopes}) when is_list(scopes), do: scopes
  defp extract_scopes(_), do: []

  defp extract_expires_at(%{expires_at: %DateTime{} = dt}), do: dt

  defp extract_expires_at(%{expires_at: str}) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp extract_expires_at(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
