defmodule ExClaw.CredentialVault.Supervisor do
  @moduledoc """
  Supervises the Credential Vault subsystem:
  - CredentialVault (encrypted credential store)
  - LeaseManager (scoped lease issuance + ETS)
  - TokenRefreshWorker (proactive OAuth2 refresh)
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:exclaw, ExClaw.CredentialVault, [])

    encryption_key_base = config[:encryption_key_base]

    encryption_key =
      if encryption_key_base do
        :crypto.hash(:sha256, encryption_key_base)
      else
        raise "CredentialVault requires SECRET_KEY_BASE (config :exclaw, ExClaw.CredentialVault, encryption_key_base: ...)"
      end

    children = [
      {ExClaw.CredentialVault,
       name: ExClaw.CredentialVault,
       encryption_key: encryption_key},
      {ExClaw.CredentialVault.LeaseManager,
       name: ExClaw.CredentialVault.LeaseManager,
       vault: ExClaw.CredentialVault},
      {ExClaw.CredentialVault.TokenRefreshWorker,
       name: ExClaw.CredentialVault.TokenRefreshWorker,
       vault: ExClaw.CredentialVault,
       check_interval: config[:refresh_interval_ms] || :timer.minutes(5),
       refresh_threshold: config[:refresh_threshold] || 600}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
