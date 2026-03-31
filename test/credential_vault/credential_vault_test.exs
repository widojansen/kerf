defmodule ExClaw.CredentialVaultTest do
  use ExClaw.DataCase, async: false

  alias ExClaw.CredentialVault
  alias ExClaw.CredentialVault.Credential

  @vault_name :test_credential_vault

  setup do
    ExClaw.Repo.delete_all(Credential)

    encryption_key = :crypto.hash(:sha256, "test-vault-secret")

    {:ok, pid} =
      CredentialVault.start_link(
        name: @vault_name,
        encryption_key: encryption_key
      )

    allow_repo(pid)

    %{vault: @vault_name, key: encryption_key}
  end

  describe "store/5" do
    test "stores an OAuth2 credential", %{vault: vault} do
      data = %{
        client_id: "google-client-id",
        client_secret: "google-secret",
        access_token: "ya29.token",
        refresh_token: "1//refresh",
        token_url: "https://oauth2.googleapis.com/token",
        scopes: ["gmail.readonly"],
        expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      }

      assert {:ok, cred} = CredentialVault.store(vault, "gmail", :oauth2, data, group_id: "personal")
      assert cred.name == "gmail"
      assert cred.type == :oauth2
      assert cred.group_id == "personal"
    end

    test "stores a bearer_token credential", %{vault: vault} do
      data = %{token: "sk_live_123", base_url: "https://api.stripe.com"}
      assert {:ok, cred} = CredentialVault.store(vault, "stripe", :bearer_token, data)
      assert cred.type == :bearer_token
    end

    test "rejects invalid credential type", %{vault: vault} do
      assert {:error, _} = CredentialVault.store(vault, "x", :invalid_type, %{})
    end

    test "enforces unique (name, group_id)", %{vault: vault} do
      data = %{token: "t1"}
      assert {:ok, _} = CredentialVault.store(vault, "svc", :bearer_token, data, group_id: "g1")
      assert {:error, _} = CredentialVault.store(vault, "svc", :bearer_token, data, group_id: "g1")
    end
  end

  describe "get/2" do
    test "retrieves decrypted credential", %{vault: vault} do
      data = %{access_token: "ya29.secret", refresh_token: "1//rt"}
      {:ok, cred} = CredentialVault.store(vault, "gmail", :oauth2, data)

      assert {:ok, decrypted} = CredentialVault.get(vault, cred.id)
      assert decrypted.decrypted_data["access_token"] == "ya29.secret"
    end

    test "returns error for non-existent credential", %{vault: vault} do
      assert {:error, :not_found} = CredentialVault.get(vault, Ecto.UUID.generate())
    end
  end

  describe "update/4" do
    test "updates credential data", %{vault: vault} do
      {:ok, cred} = CredentialVault.store(vault, "gmail", :oauth2, %{access_token: "old"})
      assert :ok = CredentialVault.update(vault, cred.id, %{access_token: "new"})

      {:ok, updated} = CredentialVault.get(vault, cred.id)
      assert updated.decrypted_data["access_token"] == "new"
    end

    test "updates expires_at", %{vault: vault} do
      {:ok, cred} = CredentialVault.store(vault, "svc", :bearer_token, %{token: "t"})
      expires = DateTime.utc_now() |> DateTime.add(7200)
      assert :ok = CredentialVault.update(vault, cred.id, %{token: "t"}, expires_at: expires)

      {:ok, updated} = CredentialVault.get(vault, cred.id)
      assert updated.expires_at
    end
  end

  describe "delete/2" do
    test "deletes a credential", %{vault: vault} do
      {:ok, cred} = CredentialVault.store(vault, "doomed", :bearer_token, %{token: "x"})
      assert :ok = CredentialVault.delete(vault, cred.id)
      assert {:error, :not_found} = CredentialVault.get(vault, cred.id)
    end
  end

  describe "list/2" do
    test "lists credentials with metadata only", %{vault: vault} do
      {:ok, _} = CredentialVault.store(vault, "gmail", :oauth2, %{access_token: "s1"}, group_id: "p")
      {:ok, _} = CredentialVault.store(vault, "stripe", :bearer_token, %{token: "s2"})

      results = CredentialVault.list(vault)
      assert length(results) == 2
      refute Enum.any?(results, &Map.has_key?(&1, :decrypted_data))
    end

    test "filters by group_id", %{vault: vault} do
      {:ok, _} = CredentialVault.store(vault, "a", :bearer_token, %{token: "t"}, group_id: "g1")
      {:ok, _} = CredentialVault.store(vault, "b", :bearer_token, %{token: "t"}, group_id: "g2")

      assert length(CredentialVault.list(vault, group_id: "g1")) == 1
    end

    test "filters by type", %{vault: vault} do
      {:ok, _} = CredentialVault.store(vault, "a", :oauth2, %{access_token: "t"})
      {:ok, _} = CredentialVault.store(vault, "b", :bearer_token, %{token: "t"})

      assert length(CredentialVault.list(vault, type: :oauth2)) == 1
    end
  end
end
