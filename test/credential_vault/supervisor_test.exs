defmodule Kerf.CredentialVault.SupervisorTest do
  use Kerf.DataCase, async: false

  alias Kerf.CredentialVault
  alias Kerf.CredentialVault.{LeaseManager, Credential, Policy}

  @encryption_key :crypto.hash(:sha256, "test-supervisor-key")

  setup do
    Kerf.Repo.delete_all(Policy)
    Kerf.Repo.delete_all(Credential)
    :ok
  end

  describe "full lifecycle" do
    test "store credential → create policy → acquire lease → proxy request → release lease" do
      # Start the vault and lease manager manually (supervisor tested via compilation)
      vault_name = :test_sup_vault
      lm_name = :test_sup_lm

      {:ok, vault_pid} =
        CredentialVault.start_link(name: vault_name, encryption_key: @encryption_key)

      allow_repo(vault_pid)

      {:ok, lm_pid} =
        LeaseManager.start_link(name: lm_name, vault: vault_name)

      allow_repo(lm_pid)

      # 1. Store a credential
      {:ok, cred} =
        CredentialVault.store(vault_name, "test_api", :bearer_token, %{
          token: "secret-api-key-123",
          base_url: "https://api.example.com"
        })

      assert cred.name == "test_api"
      assert cred.type == :bearer_token

      # 2. Create a policy
      {:ok, _} =
        %Policy{}
        |> Policy.changeset(%{
          agent_module: "Elixir.FullLifecycleAgent",
          credential_name: "test_api",
          allowed_scopes: ["read", "write"]
        })
        |> Kerf.Repo.insert()

      # 3. Acquire a lease
      {:ok, lease} =
        LeaseManager.acquire(lm_name, FullLifecycleAgent, "test_api", ["read"])

      assert lease.access_token == "secret-api-key-123"
      assert lease.scopes == ["read"]
      assert LeaseManager.valid?(lm_name, lease.id)

      # 4. Make a proxied request
      http_client = fn _method, _url, opts ->
        headers = Keyword.get(opts, :headers, [])
        {_, auth} = Enum.find(headers, fn {k, _} -> k == "authorization" end)

        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"authenticated_with" => auth})
         }}
      end

      {:ok, response} =
        Kerf.CredentialVault.Proxy.request(
          lease,
          :get,
          "https://api.example.com/data",
          http_client: http_client,
          lease_manager: lm_name,
          vault: vault_name
        )

      body = Jason.decode!(response.body)
      assert body["authenticated_with"] == "Bearer secret-api-key-123"

      # 5. Release the lease
      :ok = LeaseManager.release(lm_name, lease.id)
      assert LeaseManager.valid?(lm_name, lease.id) == false

      # 6. Verify credential listing shows metadata only
      [listed] = CredentialVault.list(vault_name)
      assert listed.name == "test_api"
      refute Map.has_key?(listed, :decrypted_data)
    end

    test "kill switch revokes all leases" do
      vault_name = :test_kill_vault
      lm_name = :test_kill_lm

      {:ok, vault_pid} =
        CredentialVault.start_link(name: vault_name, encryption_key: @encryption_key)

      allow_repo(vault_pid)

      {:ok, lm_pid} =
        LeaseManager.start_link(name: lm_name, vault: vault_name)

      allow_repo(lm_pid)

      {:ok, _} =
        CredentialVault.store(vault_name, "svc", :bearer_token, %{token: "t"})

      {:ok, _} =
        %Policy{}
        |> Policy.changeset(%{
          agent_module: "Elixir.KillAgent",
          credential_name: "svc",
          allowed_scopes: ["read"]
        })
        |> Kerf.Repo.insert()

      {:ok, lease1} = LeaseManager.acquire(lm_name, KillAgent, "svc", ["read"])
      {:ok, lease2} = LeaseManager.acquire(lm_name, KillAgent, "svc", ["read"])

      assert length(LeaseManager.active_leases(lm_name)) == 2

      :ok = LeaseManager.revoke_all(lm_name)

      assert LeaseManager.active_leases(lm_name) == []
      assert LeaseManager.valid?(lm_name, lease1.id) == false
      assert LeaseManager.valid?(lm_name, lease2.id) == false
    end
  end
end
