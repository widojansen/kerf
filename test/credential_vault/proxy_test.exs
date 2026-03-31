defmodule ExClaw.CredentialVault.ProxyTest do
  use ExClaw.DataCase, async: false

  alias ExClaw.CredentialVault
  alias ExClaw.CredentialVault.{Proxy, LeaseManager, Credential, Policy, Lease}

  @vault_name :test_proxy_vault
  @lm_name :test_proxy_lm
  @encryption_key :crypto.hash(:sha256, "test-proxy-key")

  setup do
    ExClaw.Repo.delete_all(Policy)
    ExClaw.Repo.delete_all(Credential)

    {:ok, vault_pid} =
      CredentialVault.start_link(name: @vault_name, encryption_key: @encryption_key)

    allow_repo(vault_pid)

    {:ok, _} =
      CredentialVault.store(@vault_name, "stripe", :bearer_token, %{
        token: "sk_live_secret_key",
        base_url: "https://api.stripe.com"
      })

    {:ok, gmail_cred} =
      CredentialVault.store(@vault_name, "gmail", :oauth2, %{
        access_token: "ya29.gmail-token",
        refresh_token: "1//refresh-token",
        client_id: "client-id",
        client_secret: "client-secret",
        token_url: "https://oauth2.googleapis.com/token",
        scopes: ["gmail.readonly"]
      })

    {:ok, _} =
      %Policy{}
      |> Policy.changeset(%{
        agent_module: "Elixir.ProxyTestAgent",
        credential_name: "stripe",
        allowed_scopes: ["read_charges"]
      })
      |> ExClaw.Repo.insert()

    {:ok, _} =
      %Policy{}
      |> Policy.changeset(%{
        agent_module: "Elixir.ProxyTestAgent",
        credential_name: "gmail",
        allowed_scopes: ["gmail.readonly"]
      })
      |> ExClaw.Repo.insert()

    {:ok, lm_pid} =
      LeaseManager.start_link(name: @lm_name, vault: @vault_name)

    allow_repo(lm_pid)

    # Acquire leases
    {:ok, stripe_lease} =
      LeaseManager.acquire(@lm_name, ProxyTestAgent, "stripe", ["read_charges"])

    {:ok, gmail_lease} =
      LeaseManager.acquire(@lm_name, ProxyTestAgent, "gmail", ["gmail.readonly"])

    %{
      stripe_lease: stripe_lease,
      gmail_lease: gmail_lease,
      gmail_id: gmail_cred.id,
      lm: @lm_name,
      vault: @vault_name
    }
  end

  describe "request/4" do
    test "makes authenticated request with bearer token", %{stripe_lease: lease} do
      http_client = fn method, url, opts ->
        headers = Keyword.get(opts, :headers, [])
        auth = Enum.find(headers, fn {k, _} -> k == "authorization" end)

        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{
             "method" => to_string(method),
             "url" => url,
             "auth" => elem(auth, 1)
           })
         }}
      end

      assert {:ok, response} =
               Proxy.request(lease, :get, "https://api.stripe.com/v1/charges",
                 http_client: http_client,
                 lease_manager: @lm_name
               )

      assert response.status == 200
      body = Jason.decode!(response.body)
      assert body["auth"] == "Bearer sk_live_secret_key"
      assert body["method"] == "get"
    end

    test "returns error for expired lease", %{lm: lm} do
      {:ok, lease} =
        LeaseManager.acquire(lm, ProxyTestAgent, "stripe", ["read_charges"], ttl: 1)

      Process.sleep(1100)

      http_client = fn _method, _url, _opts ->
        {:ok, %{status: 200, headers: [], body: "{}"}}
      end

      assert {:error, :lease_expired} =
               Proxy.request(lease, :get, "https://api.stripe.com/v1/charges",
                 http_client: http_client,
                 lease_manager: lm
               )
    end

    test "retries once on 401 with OAuth2 refresh", %{gmail_lease: lease, vault: vault} do
      call_count = :counters.new(1, [])

      http_client = fn _method, url, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          # Token refresh endpoint
          url == "https://oauth2.googleapis.com/token" ->
            {:ok,
             %{
               status: 200,
               headers: [],
               body:
                 Jason.encode!(%{
                   "access_token" => "ya29.refreshed-token",
                   "expires_in" => 3600
                 })
             }}

          # First API call returns 401
          count == 0 ->
            {:ok, %{status: 401, headers: [], body: Jason.encode!(%{"error" => "Unauthorized"})}}

          # Retry succeeds
          true ->
            {:ok,
             %{status: 200, headers: [], body: Jason.encode!(%{"data" => "success"})}}
        end
      end

      assert {:ok, response} =
               Proxy.request(lease, :get, "https://gmail.googleapis.com/gmail/v1/users/me/messages",
                 http_client: http_client,
                 lease_manager: @lm_name,
                 vault: vault
               )

      assert response.status == 200
    end

    test "returns refresh_failed on second 401", %{gmail_lease: lease, vault: vault} do
      http_client = fn _method, url, _opts ->
        if url == "https://oauth2.googleapis.com/token" do
          # Refresh succeeds but new token is also rejected
          {:ok,
           %{
             status: 200,
             headers: [],
             body:
               Jason.encode!(%{
                 "access_token" => "ya29.still-bad",
                 "expires_in" => 3600
               })
           }}
        else
          # Always returns 401
          {:ok, %{status: 401, headers: [], body: Jason.encode!(%{"error" => "Unauthorized"})}}
        end
      end

      assert {:error, :refresh_failed} =
               Proxy.request(lease, :get, "https://gmail.googleapis.com/gmail/v1/messages",
                 http_client: http_client,
                 lease_manager: @lm_name,
                 vault: vault
               )
    end

    test "injects correct Authorization header for bearer_token", %{stripe_lease: lease} do
      test_pid = self()

      http_client = fn _method, _url, opts ->
        headers = Keyword.get(opts, :headers, [])
        send(test_pid, {:headers, headers})
        {:ok, %{status: 200, headers: [], body: "{}"}}
      end

      Proxy.request(lease, :get, "https://api.stripe.com/v1/charges",
        http_client: http_client,
        lease_manager: @lm_name
      )

      assert_receive {:headers, headers}
      {_, auth_value} = Enum.find(headers, fn {k, _} -> k == "authorization" end)
      assert auth_value == "Bearer sk_live_secret_key"
    end
  end

  describe "rate limiting" do
    test "returns rate_limited when bucket is empty", %{stripe_lease: lease} do
      # Create a rate limiter ETS with an empty bucket
      rate_table = :ets.new(:test_proxy_rates, [:set, :public])

      :ets.insert(rate_table, {
        lease.credential_id,
        %{
          tokens: 0.0,
          max_tokens: 10.0,
          refill_rate: 10.0,
          last_refill: System.monotonic_time(:millisecond)
        }
      })

      http_client = fn _method, _url, _opts ->
        {:ok, %{status: 200, headers: [], body: "{}"}}
      end

      assert {:error, {:rate_limited, _retry_after}} =
               Proxy.request(lease, :get, "https://api.stripe.com/v1/charges",
                 http_client: http_client,
                 lease_manager: @lm_name,
                 rate_table: rate_table
               )

      :ets.delete(rate_table)
    end
  end
end
