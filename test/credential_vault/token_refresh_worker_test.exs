defmodule Kerf.CredentialVault.TokenRefreshWorkerTest do
  use Kerf.DataCase, async: false

  alias Kerf.CredentialVault
  alias Kerf.CredentialVault.{TokenRefreshWorker, Credential}

  @vault_name :test_trw_vault
  @worker_name :test_token_refresh_worker
  @encryption_key :crypto.hash(:sha256, "test-trw-key")

  setup do
    Kerf.Repo.delete_all(Credential)

    {:ok, vault_pid} =
      CredentialVault.start_link(name: @vault_name, encryption_key: @encryption_key)

    allow_repo(vault_pid)

    %{vault: @vault_name}
  end

  describe "refresh cycle" do
    test "refreshes OAuth2 token expiring within threshold", %{vault: vault} do
      # Store a credential that expires in 5 minutes (within the 10-minute threshold)
      {:ok, cred} =
        CredentialVault.store(vault, "gmail", :oauth2, %{
          client_id: "client-id",
          client_secret: "client-secret",
          access_token: "old-access-token",
          refresh_token: "valid-refresh-token",
          token_url: "https://oauth2.googleapis.com/token",
          expires_at: DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
        })

      test_pid = self()

      # Mock HTTP client that returns a new token
      http_client = fn url, body, _headers ->
        send(test_pid, {:refresh_called, url, body})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "new-access-token",
               "expires_in" => 3600,
               "token_type" => "Bearer"
             })
         }}
      end

      {:ok, worker_pid} =
        TokenRefreshWorker.start_link(
          name: @worker_name,
          vault: vault,
          check_interval: 100,
          refresh_threshold: 600,
          http_client: http_client
        )

      allow_repo(worker_pid)

      # Wait for the refresh cycle
      assert_receive {:refresh_called, url, body}, 2000
      assert url == "https://oauth2.googleapis.com/token"
      assert body =~ "valid-refresh-token"

      # Verify the credential was updated
      Process.sleep(100)
      {:ok, updated} = CredentialVault.get(vault, cred.id)
      assert updated.decrypted_data["access_token"] == "new-access-token"
    end

    test "skips non-OAuth2 credentials", %{vault: vault} do
      {:ok, _} =
        CredentialVault.store(vault, "stripe", :bearer_token, %{
          token: "sk_live_123"
        })

      test_pid = self()

      http_client = fn _url, _body, _headers ->
        send(test_pid, :refresh_called)
        {:ok, %{status: 200, body: Jason.encode!(%{"access_token" => "x"})}}
      end

      {:ok, worker_pid} =
        TokenRefreshWorker.start_link(
          name: :"test_trw_skip",
          vault: vault,
          check_interval: 100,
          refresh_threshold: 600,
          http_client: http_client
        )

      allow_repo(worker_pid)

      # Should NOT trigger a refresh for bearer_token type
      Process.sleep(300)
      refute_received :refresh_called
    end

    test "skips OAuth2 credentials not expiring soon", %{vault: vault} do
      {:ok, _} =
        CredentialVault.store(vault, "gmail", :oauth2, %{
          access_token: "valid-token",
          refresh_token: "rt",
          token_url: "https://oauth2.googleapis.com/token",
          expires_at: DateTime.utc_now() |> DateTime.add(7200) |> DateTime.to_iso8601()
        })

      test_pid = self()

      http_client = fn _url, _body, _headers ->
        send(test_pid, :refresh_called)
        {:ok, %{status: 200, body: Jason.encode!(%{"access_token" => "x"})}}
      end

      {:ok, worker_pid} =
        TokenRefreshWorker.start_link(
          name: :"test_trw_not_expiring",
          vault: vault,
          check_interval: 100,
          refresh_threshold: 600,
          http_client: http_client
        )

      allow_repo(worker_pid)

      Process.sleep(300)
      refute_received :refresh_called
    end

    test "handles refresh failure without crashing", %{vault: vault} do
      {:ok, cred} =
        CredentialVault.store(vault, "gmail", :oauth2, %{
          access_token: "old-token",
          refresh_token: "bad-refresh-token",
          token_url: "https://oauth2.googleapis.com/token",
          expires_at: DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
        })

      http_client = fn _url, _body, _headers ->
        {:ok, %{status: 401, body: Jason.encode!(%{"error" => "invalid_grant"})}}
      end

      {:ok, worker_pid} =
        TokenRefreshWorker.start_link(
          name: :"test_trw_fail",
          vault: vault,
          check_interval: 100,
          refresh_threshold: 600,
          http_client: http_client
        )

      allow_repo(worker_pid)

      # Worker should not crash
      Process.sleep(300)
      assert Process.alive?(worker_pid)

      # Original credential should be unchanged
      {:ok, unchanged} = CredentialVault.get(vault, cred.id)
      assert unchanged.decrypted_data["access_token"] == "old-token"
    end
  end
end
