defmodule ExClaw.CredentialVault.LeaseManagerTest do
  use ExClaw.DataCase, async: false

  alias ExClaw.CredentialVault
  alias ExClaw.CredentialVault.{LeaseManager, Credential, Policy}

  @vault_name :test_lm_vault
  @lm_name :test_lease_manager
  @encryption_key :crypto.hash(:sha256, "test-lease-mgr-key")

  setup do
    ExClaw.Repo.delete_all(Policy)
    ExClaw.Repo.delete_all(Credential)

    {:ok, vault_pid} =
      CredentialVault.start_link(name: @vault_name, encryption_key: @encryption_key)

    allow_repo(vault_pid)

    # Store a test credential
    {:ok, gmail_cred} =
      CredentialVault.store(@vault_name, "gmail", :oauth2, %{
        access_token: "ya29.test-token",
        refresh_token: "1//refresh",
        scopes: ["gmail.readonly", "gmail.labels", "gmail.modify"]
      })

    # Create a policy allowing the test agent to access gmail
    {:ok, _policy} =
      %Policy{}
      |> Policy.changeset(%{
        agent_module: "Elixir.TestAgent",
        credential_name: "gmail",
        allowed_scopes: ["gmail.readonly", "gmail.labels"],
        max_lease_ttl: 300
      })
      |> ExClaw.Repo.insert()

    {:ok, lm_pid} =
      LeaseManager.start_link(
        name: @lm_name,
        vault: @vault_name
      )

    allow_repo(lm_pid)

    %{
      lm: @lm_name,
      vault: @vault_name,
      gmail_id: gmail_cred.id
    }
  end

  describe "acquire/5" do
    test "acquires a lease with valid scopes", %{lm: lm} do
      assert {:ok, lease} =
               LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])

      assert lease.id
      assert lease.credential_name == "gmail"
      assert lease.scopes == ["gmail.readonly"]
      assert lease.access_token == "ya29.test-token"
      assert lease.agent_module == "Elixir.TestAgent"
      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt
    end

    test "scope intersection — only grants policy-allowed scopes", %{lm: lm} do
      # Policy allows gmail.readonly + gmail.labels, but NOT gmail.modify
      assert {:ok, lease} =
               LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly", "gmail.labels"])

      assert Enum.sort(lease.scopes) == ["gmail.labels", "gmail.readonly"]
    end

    test "rejects scope not in policy", %{lm: lm} do
      assert {:error, :scope_denied} =
               LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.modify"])
    end

    test "returns error for non-existent credential (no policy)", %{lm: lm} do
      # No policy exists for "nonexistent" credential, so policy_violation comes first
      assert {:error, :policy_violation} =
               LeaseManager.acquire(lm, TestAgent, "nonexistent", ["some.scope"])
    end

    test "returns error when credential is missing but policy exists", %{lm: lm} do
      # Create a policy for a credential that doesn't exist in the vault
      {:ok, _} =
        %Policy{}
        |> Policy.changeset(%{
          agent_module: "Elixir.TestAgent",
          credential_name: "ghost",
          allowed_scopes: ["read"]
        })
        |> ExClaw.Repo.insert()

      assert {:error, :not_found} =
               LeaseManager.acquire(lm, TestAgent, "ghost", ["read"])
    end

    test "returns error when no policy exists for agent", %{lm: lm} do
      assert {:error, :policy_violation} =
               LeaseManager.acquire(lm, UnauthorizedAgent, "gmail", ["gmail.readonly"])
    end

    test "respects custom TTL", %{lm: lm} do
      assert {:ok, lease} =
               LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"], ttl: 60)

      # Lease should expire in ~60 seconds (with some tolerance)
      diff = DateTime.diff(lease.expires_at, DateTime.utc_now())
      assert diff >= 55 and diff <= 65
    end

    test "enforces max_lease_ttl from policy", %{lm: lm} do
      # Policy max_lease_ttl is 300; requesting 600 should be capped
      assert {:ok, lease} =
               LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"], ttl: 600)

      diff = DateTime.diff(lease.expires_at, DateTime.utc_now())
      assert diff <= 305
    end
  end

  describe "release/2" do
    test "releases an active lease", %{lm: lm} do
      {:ok, lease} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])
      assert :ok = LeaseManager.release(lm, lease.id)
      assert LeaseManager.valid?(lm, lease.id) == false
    end

    test "returns error for unknown lease", %{lm: lm} do
      assert {:error, :not_found} = LeaseManager.release(lm, "nonexistent")
    end
  end

  describe "valid?/2" do
    test "returns true for active lease", %{lm: lm} do
      {:ok, lease} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])
      assert LeaseManager.valid?(lm, lease.id) == true
    end

    test "returns false for released lease", %{lm: lm} do
      {:ok, lease} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])
      LeaseManager.release(lm, lease.id)
      assert LeaseManager.valid?(lm, lease.id) == false
    end

    test "returns false for expired lease", %{lm: lm} do
      {:ok, lease} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"], ttl: 1)
      # Wait for expiry
      Process.sleep(1100)
      assert LeaseManager.valid?(lm, lease.id) == false
    end

    test "returns false for unknown lease", %{lm: lm} do
      assert LeaseManager.valid?(lm, "nonexistent") == false
    end
  end

  describe "process monitoring — crash cleanup" do
    test "lease is cleaned up when agent process crashes", %{lm: lm} do
      # Spawn a process that acquires a lease then crashes
      test_pid = self()

      agent_pid =
        spawn(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(ExClaw.Repo, test_pid, self())

          {:ok, lease} =
            LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])

          send(test_pid, {:lease_id, lease.id})
          # Wait a bit then crash
          Process.sleep(50)
          exit(:crash)
        end)

      # Get the lease ID
      lease_id =
        receive do
          {:lease_id, id} -> id
        after
          1000 -> flunk("Didn't receive lease_id")
        end

      # Wait for the monitored process to crash and be detected
      ref = Process.monitor(agent_pid)

      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        1000 -> flunk("Agent didn't crash")
      end

      # Give LeaseManager time to process the :DOWN message
      Process.sleep(50)

      assert LeaseManager.valid?(lm, lease_id) == false
    end
  end

  describe "active_leases/1" do
    test "returns all active leases", %{lm: lm} do
      {:ok, _} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])
      {:ok, _} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.labels"])

      leases = LeaseManager.active_leases(lm)
      assert length(leases) == 2
    end

    test "excludes released leases", %{lm: lm} do
      {:ok, lease1} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])
      {:ok, _lease2} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.labels"])

      LeaseManager.release(lm, lease1.id)

      leases = LeaseManager.active_leases(lm)
      assert length(leases) == 1
    end
  end

  describe "revoke_all/1" do
    test "revokes all active leases (kill switch)", %{lm: lm} do
      {:ok, _} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.readonly"])
      {:ok, _} = LeaseManager.acquire(lm, TestAgent, "gmail", ["gmail.labels"])

      assert :ok = LeaseManager.revoke_all(lm)
      assert LeaseManager.active_leases(lm) == []
    end
  end
end
