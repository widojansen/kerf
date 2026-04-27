defmodule Kerf.Agents.EmailTriage.Supervisor do
  @moduledoc """
  Supervisor for the Email Triage Agent subsystem.
  Starts the EmailIngestor and EmailTriage GenServers.
  """
  use Supervisor

  alias Kerf.Ingestors.Email.{GmailClient, EmailIngestor}
  alias Kerf.Agents.EmailTriage.EmailTriage
  alias Kerf.CredentialVault

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ingestor_config = Application.get_env(:kerf, EmailIngestor, [])
    triage_config = Application.get_env(:kerf, Kerf.Agents.EmailTriage, [])
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
             repo: Kerf.Repo,
             poll_interval_ms: Keyword.get(config, :poll_interval_ms, 300_000),
             access_token_fn: build_access_token_fn(credential_name),
             gmail_client: &GmailClient.fetch_new/2,
             triage_fn: fn doc_ids ->
               EmailTriage.triage(EmailTriage, doc_ids)
             end
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
             repo: Kerf.Repo,
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
          # Resolve label names to IDs in the :add list
          opts = resolve_label_ids(access_token, opts)
          GmailClient.modify_message(access_token, message_id, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_label_ids(access_token, opts) do
    case Keyword.get(opts, :add, []) do
      [] ->
        opts

      labels ->
        resolved =
          Enum.map(labels, fn label ->
            if String.starts_with?(label, "Label_") or label == "UNREAD" or label == "STARRED" or label == "INBOX" do
              label
            else
              case GmailClient.resolve_label(access_token, label) do
                {:ok, id} -> id
                {:error, _} -> label
              end
            end
          end)

        Keyword.put(opts, :add, resolved)
    end
  end
end
