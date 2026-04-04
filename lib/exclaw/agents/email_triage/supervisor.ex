defmodule ExClaw.Agents.EmailTriage.Supervisor do
  @moduledoc """
  Supervisor for the Email Triage Agent subsystem.
  Starts the EmailIngestor and EmailTriage GenServers.
  """
  use Supervisor

  alias ExClaw.Ingestors.Email.{GmailClient, EmailIngestor}
  alias ExClaw.Agents.EmailTriage.EmailTriage
  alias ExClaw.CredentialVault

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ingestor_config = Application.get_env(:exclaw, EmailIngestor, [])
    triage_config = Application.get_env(:exclaw, ExClaw.Agents.EmailTriage, [])
    credential_name = Keyword.get(ingestor_config, :credential_name, "gmail_oauth")

    children =
      []
      |> maybe_add_ingestor(ingestor_config, credential_name)
      |> maybe_add_triage(triage_config, credential_name)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_add_ingestor(children, config, credential_name) do
    if Keyword.get(config, :enabled, false) do
      children ++
        [
          {EmailIngestor,
           [
             name: EmailIngestor,
             repo: ExClaw.Repo,
             poll_interval_ms: Keyword.get(config, :poll_interval_ms, 300_000),
             access_token_fn: build_access_token_fn(credential_name),
             gmail_client: &GmailClient.fetch_new/2
           ]}
        ]
    else
      children
    end
  end

  defp maybe_add_triage(children, config, credential_name) do
    if Keyword.get(config, :enabled, false) do
      children ++
        [
          {EmailTriage,
           [
             name: EmailTriage,
             repo: ExClaw.Repo,
             interest_threshold: Keyword.get(config, :interest_threshold, 0.5),
             high_priority_threshold: Keyword.get(config, :high_priority_threshold, 4),
             gmail_fn: build_gmail_fn(credential_name)
           ]}
        ]
    else
      children
    end
  end

  defp build_access_token_fn(credential_name) do
    fn ->
      case CredentialVault.get_by_name(CredentialVault, credential_name) do
        {:ok, cred} -> {:ok, cred.decrypted_data["access_token"]}
        {:error, _} = err -> err
      end
    end
  end

  defp build_gmail_fn(credential_name) do
    fn _token, message_id, opts ->
      case CredentialVault.get_by_name(CredentialVault, credential_name) do
        {:ok, cred} ->
          access_token = cred.decrypted_data["access_token"]
          GmailClient.modify_message(access_token, message_id, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
