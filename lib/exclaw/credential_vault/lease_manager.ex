defmodule ExClaw.CredentialVault.LeaseManager do
  @moduledoc """
  Manages scoped, time-limited credential leases backed by ETS.

  Agents request leases via `acquire/5`. The LeaseManager:
  1. Validates the policy allows the requested scopes
  2. Retrieves the decrypted credential from the Vault
  3. Issues a lease with an opaque token
  4. Monitors the agent process — lease auto-revokes on crash

  Leases are ephemeral (ETS-only). A restart revokes all active leases by design.
  """
  use GenServer

  alias ExClaw.CredentialVault
  alias ExClaw.CredentialVault.{Lease, Policy}
  import Ecto.Query

  @default_ttl 300
  @sweep_interval :timer.seconds(60)

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def acquire(lm \\ __MODULE__, agent_module, credential_name, required_scopes, opts \\ []) do
    GenServer.call(lm, {:acquire, agent_module, credential_name, required_scopes, opts})
  end

  def release(lm \\ __MODULE__, lease_id) do
    GenServer.call(lm, {:release, lease_id})
  end

  def valid?(lm \\ __MODULE__, lease_id) do
    GenServer.call(lm, {:valid?, lease_id})
  end

  def active_leases(lm \\ __MODULE__) do
    GenServer.call(lm, :active_leases)
  end

  def revoke_all(lm \\ __MODULE__) do
    GenServer.call(lm, :revoke_all)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    vault = Keyword.get(opts, :vault, CredentialVault)
    table = :ets.new(:credential_vault_leases, [:set, :private])
    schedule_sweep()

    {:ok,
     %{
       vault: vault,
       table: table,
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:acquire, agent_module, cred_name, required_scopes, opts}, {caller_pid, _}, state) do
    agent_module_str = to_string(agent_module)

    with {:ok, policy} <- lookup_policy(agent_module_str, cred_name),
         :ok <- check_scopes(required_scopes, policy.allowed_scopes),
         {:ok, credential} <- find_credential_by_name(state.vault, cred_name),
         access_token <- extract_access_token(credential) do
      ttl = min(Keyword.get(opts, :ttl, @default_ttl), policy.max_lease_ttl)

      lease = %Lease{
        id: generate_lease_id(),
        credential_id: credential.id,
        credential_name: cred_name,
        agent_module: agent_module_str,
        agent_pid: caller_pid,
        scopes: required_scopes,
        access_token: access_token,
        expires_at: DateTime.utc_now() |> DateTime.add(ttl),
        issued_at: DateTime.utc_now(),
        group_id: Keyword.get(opts, :group_id)
      }

      # Store in ETS
      :ets.insert(state.table, {lease.id, lease})

      # Monitor the agent process
      ref = Process.monitor(caller_pid)
      monitors = Map.put(state.monitors, caller_pid, {ref, [lease.id | get_lease_ids(state.monitors, caller_pid)]})

      {:reply, {:ok, lease}, %{state | monitors: monitors}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, lease_id}, _from, state) do
    case :ets.lookup(state.table, lease_id) do
      [{^lease_id, _lease}] ->
        :ets.delete(state.table, lease_id)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:valid?, lease_id}, _from, state) do
    result =
      case :ets.lookup(state.table, lease_id) do
        [{^lease_id, lease}] ->
          not lease.revoked? and DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt

        [] ->
          false
      end

    {:reply, result, state}
  end

  def handle_call(:active_leases, _from, state) do
    now = DateTime.utc_now()

    leases =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_id, lease} -> lease end)
      |> Enum.filter(fn lease ->
        not lease.revoked? and DateTime.compare(lease.expires_at, now) == :gt
      end)

    {:reply, leases, state}
  end

  def handle_call(:revoke_all, _from, state) do
    :ets.delete_all_objects(state.table)

    # Demonitor all
    for {_pid, {ref, _ids}} <- state.monitors do
      Process.demonitor(ref, [:flush])
    end

    {:reply, :ok, %{state | monitors: %{}}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.get(state.monitors, pid) do
      {_ref, lease_ids} ->
        for lid <- lease_ids, do: :ets.delete(state.table, lid)
        {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep_expired, state) do
    now = DateTime.utc_now()

    :ets.tab2list(state.table)
    |> Enum.each(fn {id, lease} ->
      if DateTime.compare(lease.expires_at, now) != :gt do
        :ets.delete(state.table, id)
      end
    end)

    schedule_sweep()
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval)
  end

  defp generate_lease_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp lookup_policy(agent_module_str, cred_name) do
    query =
      from(p in Policy,
        where: p.agent_module == ^agent_module_str and p.credential_name == ^cred_name,
        where: is_nil(p.group_id),
        limit: 1
      )

    case ExClaw.Repo.one(query) do
      nil -> {:error, :policy_violation}
      policy -> {:ok, policy}
    end
  end

  defp check_scopes(required, allowed) do
    allowed_set = MapSet.new(allowed)

    if Enum.all?(required, &MapSet.member?(allowed_set, &1)) do
      :ok
    else
      {:error, :scope_denied}
    end
  end

  defp find_credential_by_name(vault, name) do
    # List all, find by name, then get full decrypted credential
    credentials = CredentialVault.list(vault)

    case Enum.find(credentials, &(&1.name == name)) do
      nil -> {:error, :not_found}
      meta -> CredentialVault.get(vault, meta.id)
    end
  end

  defp extract_access_token(%{decrypted_data: data}) do
    data["access_token"] || data["token"] || data["key"]
  end

  defp get_lease_ids(monitors, pid) do
    case Map.get(monitors, pid) do
      {_ref, ids} -> ids
      nil -> []
    end
  end
end
