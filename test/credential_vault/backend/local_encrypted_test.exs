defmodule Kerf.CredentialVault.Backend.LocalEncryptedTest do
  use Kerf.DataCase, async: false

  alias Kerf.CredentialVault.Backend.LocalEncrypted
  alias Kerf.CredentialVault.Credential

  @encryption_key :crypto.hash(:sha256, "test-secret-key-base-for-credential-vault")

  setup do
    # Clean up any leftover credentials from previous test runs
    Kerf.Repo.delete_all(Credential)
    :ok
  end

  describe "store/4" do
    test "stores and encrypts an OAuth2 credential" do
      data = %{
        client_id: "google-client-id",
        client_secret: "google-client-secret",
        access_token: "ya29.access-token",
        refresh_token: "1//refresh-token",
        token_url: "https://oauth2.googleapis.com/token",
        scopes: ["gmail.readonly", "gmail.labels"],
        expires_at: DateTime.utc_now() |> DateTime.add(3600)
      }

      assert {:ok, credential} =
               LocalEncrypted.store("gmail", :oauth2, data, @encryption_key,
                 group_id: "personal"
               )

      assert credential.id
      assert credential.name == "gmail"
      assert credential.type == :oauth2
      assert credential.group_id == "personal"
      assert credential.scopes == ["gmail.readonly", "gmail.labels"]

      # The raw encrypted_data column should NOT contain the plaintext secret
      raw = Kerf.Repo.get!(Credential, credential.id)
      refute String.contains?(raw.encrypted_data, "ya29.access-token")
      refute String.contains?(raw.encrypted_data, "google-client-secret")
    end

    test "stores a bearer_token credential" do
      data = %{
        token: "sk_live_stripe_key",
        base_url: "https://api.stripe.com"
      }

      assert {:ok, credential} =
               LocalEncrypted.store("stripe", :bearer_token, data, @encryption_key)

      assert credential.name == "stripe"
      assert credential.type == :bearer_token
      assert is_nil(credential.group_id)
    end

    test "stores an api_key credential" do
      data = %{
        key: "anthropic-api-key-123",
        header_name: "x-api-key",
        base_url: "https://api.anthropic.com"
      }

      assert {:ok, credential} =
               LocalEncrypted.store("anthropic", :api_key, data, @encryption_key)

      assert credential.type == :api_key
    end

    test "enforces unique constraint on (name, group_id)" do
      data = %{token: "token-1"}

      assert {:ok, _} =
               LocalEncrypted.store("service_a", :bearer_token, data, @encryption_key,
                 group_id: "g1"
               )

      assert {:error, changeset} =
               LocalEncrypted.store("service_a", :bearer_token, data, @encryption_key,
                 group_id: "g1"
               )

      assert {"has already been taken", _} = changeset.errors[:name]
    end

    test "allows same name with different group_id" do
      data = %{token: "token-1"}

      assert {:ok, _} =
               LocalEncrypted.store("service_a", :bearer_token, data, @encryption_key,
                 group_id: "g1"
               )

      assert {:ok, _} =
               LocalEncrypted.store("service_a", :bearer_token, data, @encryption_key,
                 group_id: "g2"
               )
    end
  end

  describe "get/2" do
    test "retrieves and decrypts a stored credential" do
      data = %{
        client_id: "google-client-id",
        client_secret: "google-client-secret",
        access_token: "ya29.access-token",
        refresh_token: "1//refresh-token",
        token_url: "https://oauth2.googleapis.com/token",
        scopes: ["gmail.readonly"],
        expires_at: "2026-04-01T00:00:00Z"
      }

      {:ok, credential} = LocalEncrypted.store("gmail", :oauth2, data, @encryption_key)

      assert {:ok, decrypted} = LocalEncrypted.get(credential.id, @encryption_key)
      assert decrypted.name == "gmail"
      assert decrypted.type == :oauth2
      assert decrypted.decrypted_data["client_id"] == "google-client-id"
      assert decrypted.decrypted_data["client_secret"] == "google-client-secret"
      assert decrypted.decrypted_data["access_token"] == "ya29.access-token"
      assert decrypted.decrypted_data["refresh_token"] == "1//refresh-token"
    end

    test "returns error for non-existent credential" do
      assert {:error, :not_found} =
               LocalEncrypted.get(Ecto.UUID.generate(), @encryption_key)
    end

    test "wrong encryption key fails to decrypt" do
      data = %{token: "secret-token"}
      {:ok, credential} = LocalEncrypted.store("svc", :bearer_token, data, @encryption_key)

      wrong_key = :crypto.hash(:sha256, "wrong-key")
      assert {:error, :decryption_failed} = LocalEncrypted.get(credential.id, wrong_key)
    end
  end

  describe "update/3" do
    test "updates and re-encrypts credential data" do
      data = %{access_token: "old-token", refresh_token: "rt-1"}
      {:ok, credential} = LocalEncrypted.store("gmail", :oauth2, data, @encryption_key)

      new_data = %{access_token: "new-token", refresh_token: "rt-1"}

      assert :ok = LocalEncrypted.update(credential.id, new_data, @encryption_key)

      {:ok, updated} = LocalEncrypted.get(credential.id, @encryption_key)
      assert updated.decrypted_data["access_token"] == "new-token"
    end

    test "updates expires_at metadata" do
      data = %{access_token: "token-1"}
      {:ok, credential} = LocalEncrypted.store("gmail", :oauth2, data, @encryption_key)

      expires = DateTime.utc_now() |> DateTime.add(7200)

      assert :ok =
               LocalEncrypted.update(credential.id, data, @encryption_key, expires_at: expires)

      {:ok, updated} = LocalEncrypted.get(credential.id, @encryption_key)
      assert updated.expires_at
    end

    test "returns error for non-existent credential" do
      assert {:error, :not_found} =
               LocalEncrypted.update(Ecto.UUID.generate(), %{}, @encryption_key)
    end
  end

  describe "delete/1" do
    test "deletes a credential" do
      data = %{token: "doomed-token"}
      {:ok, credential} = LocalEncrypted.store("doomed", :bearer_token, data, @encryption_key)

      assert :ok = LocalEncrypted.delete(credential.id)
      assert {:error, :not_found} = LocalEncrypted.get(credential.id, @encryption_key)
    end

    test "returns error for non-existent credential" do
      assert {:error, :not_found} = LocalEncrypted.delete(Ecto.UUID.generate())
    end
  end

  describe "list/1" do
    test "lists credentials with metadata only — no secrets" do
      {:ok, _} =
        LocalEncrypted.store("gmail", :oauth2, %{access_token: "secret1"}, @encryption_key,
          group_id: "personal"
        )

      {:ok, _} =
        LocalEncrypted.store("stripe", :bearer_token, %{token: "secret2"}, @encryption_key)

      results = LocalEncrypted.list()
      assert length(results) == 2

      gmail = Enum.find(results, &(&1.name == "gmail"))
      assert gmail.type == :oauth2
      assert gmail.group_id == "personal"
      # Must not contain decrypted secrets
      refute Map.has_key?(gmail, :decrypted_data)
    end

    test "filters by group_id" do
      {:ok, _} =
        LocalEncrypted.store("a", :bearer_token, %{token: "t1"}, @encryption_key,
          group_id: "g1"
        )

      {:ok, _} =
        LocalEncrypted.store("b", :bearer_token, %{token: "t2"}, @encryption_key,
          group_id: "g2"
        )

      results = LocalEncrypted.list(group_id: "g1")
      assert length(results) == 1
      assert hd(results).name == "a"
    end

    test "filters by type" do
      {:ok, _} =
        LocalEncrypted.store("svc1", :oauth2, %{access_token: "t"}, @encryption_key)

      {:ok, _} =
        LocalEncrypted.store("svc2", :bearer_token, %{token: "t"}, @encryption_key)

      results = LocalEncrypted.list(type: :oauth2)
      assert length(results) == 1
      assert hd(results).name == "svc1"
    end
  end
end
