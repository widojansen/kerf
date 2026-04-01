defmodule ExClaw.Agents.EmailTriage.Supervisor do
  @moduledoc """
  Supervisor for the Email Triage Agent subsystem.
  Starts the EmailIngestor and EmailTriage GenServers.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ingestor_config = Application.get_env(:exclaw, ExClaw.Ingestors.Email.EmailIngestor, [])
    triage_config = Application.get_env(:exclaw, ExClaw.Agents.EmailTriage, [])

    children =
      []
      |> maybe_add_ingestor(ingestor_config)
      |> maybe_add_triage(triage_config)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_add_ingestor(children, config) do
    if Keyword.get(config, :enabled, false) do
      children ++
        [
          {ExClaw.Ingestors.Email.EmailIngestor,
           [
             name: ExClaw.Ingestors.Email.EmailIngestor,
             repo: ExClaw.Repo,
             poll_interval_ms: Keyword.get(config, :poll_interval_ms, 300_000)
           ]}
        ]
    else
      children
    end
  end

  defp maybe_add_triage(children, config) do
    if Keyword.get(config, :enabled, false) do
      children ++
        [
          {ExClaw.Agents.EmailTriage.EmailTriage,
           [
             name: ExClaw.Agents.EmailTriage.EmailTriage,
             repo: ExClaw.Repo,
             interest_threshold: Keyword.get(config, :interest_threshold, 0.5),
             high_priority_threshold: Keyword.get(config, :high_priority_threshold, 4)
           ]}
        ]
    else
      children
    end
  end
end
