defmodule Kerf.CredentialVault do
  @moduledoc """
  GenServer wrapping the credential storage backend.

  Serializes all credential operations through a single process to ensure
  consistency. Agents never call this directly — they use the LeaseManager.
  """
  use GenServer

  alias Kerf.CredentialVault.Backend.LocalEncrypted

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def store(vault \\ __MODULE__, name, type, data, opts \\ []) do
    GenServer.call(vault, {:store, name, type, data, opts})
  end

  def get(vault \\ __MODULE__, credential_id) do
    GenServer.call(vault, {:get, credential_id})
  end

  def get_by_name(vault \\ __MODULE__, credential_name) do
    GenServer.call(vault, {:get_by_name, credential_name})
  end

  def update(vault \\ __MODULE__, credential_id, data, opts \\ []) do
    GenServer.call(vault, {:update, credential_id, data, opts})
  end

  def delete(vault \\ __MODULE__, credential_id) do
    GenServer.call(vault, {:delete, credential_id})
  end

  def list(vault \\ __MODULE__, opts \\ []) do
    GenServer.call(vault, {:list, opts})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    encryption_key =
      Keyword.get_lazy(opts, :encryption_key, fn ->
        secret = Application.get_env(:exclaw, __MODULE__, [])[:encryption_key_base]

        if secret do
          :crypto.hash(:sha256, secret)
        else
          raise "CredentialVault requires :encryption_key or SECRET_KEY_BASE"
        end
      end)

    {:ok, %{encryption_key: encryption_key}}
  end

  @impl true
  def handle_call({:store, name, type, data, opts}, _from, state) do
    result = LocalEncrypted.store(name, type, data, state.encryption_key, opts)
    {:reply, result, state}
  end

  def handle_call({:get, credential_id}, _from, state) do
    result = LocalEncrypted.get(credential_id, state.encryption_key)
    {:reply, result, state}
  end

  def handle_call({:get_by_name, credential_name}, _from, state) do
    result = LocalEncrypted.get_by_name(credential_name, state.encryption_key)
    {:reply, result, state}
  end

  def handle_call({:update, credential_id, data, opts}, _from, state) do
    result = LocalEncrypted.update(credential_id, data, state.encryption_key, opts)
    {:reply, result, state}
  end

  def handle_call({:delete, credential_id}, _from, state) do
    result = LocalEncrypted.delete(credential_id)
    {:reply, result, state}
  end

  def handle_call({:list, opts}, _from, state) do
    result = LocalEncrypted.list(opts)
    {:reply, result, state}
  end
end
