defmodule Kerf.Application do
  @moduledoc """
  Kerf OTP Application.

  Starts only the components that are implemented.
  Components are added incrementally as they are built and tested.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Phase 1: Foundation
        Kerf.Repo,
        {Phoenix.PubSub, name: Kerf.PubSub},
        {Registry, keys: :unique, name: Kerf.SessionRegistry},
        # Task.Supervisor for async channel message handling
        {Task.Supervisor, name: Kerf.TaskSupervisor},

        # Phase 8: Telemetry (started early so all modules can emit)
        {Kerf.Telemetry.Supervisor,
         logger_opts:
           Application.get_env(:exclaw, Kerf.Telemetry.Logger, [])
           |> Keyword.put(:name, Kerf.Telemetry.Logger)},

        # BEAM VM metrics — emits [:vm, :memory], [:vm, :total_run_queue_lengths] etc.
        {:telemetry_poller, measurements: [:memory, :total_run_queue_lengths], period: 30_000},

        # Phase 1: Security (built first via TDD)
        Kerf.Security.Supervisor,

        # Phase 9: Container Manager (Docker sandbox per group)
        {Kerf.Container.Supervisor,
         manager_opts:
           Application.get_env(:exclaw, Kerf.Container.Manager, [])
           |> Keyword.put(:name, Kerf.Container.Manager)},

        # Phase 11: Tool Registry (ETS-backed, auto-registers builtins)
        {Kerf.Tools.Registry, name: Kerf.Tools.Registry, register_builtins: true},

        # Phase A.5: Structured Output SchemaRegistry
        {Kerf.StructuredOutput.SchemaRegistry,
         name: Kerf.StructuredOutput.SchemaRegistry,
         register_builtins: Application.get_env(:exclaw, Kerf.StructuredOutput, [])[:register_builtins] || false},

        # Phase 2: LLM Provider
        Kerf.LLM.Supervisor,

        # Phase 3: Agent Session
        Kerf.Agent.Supervisor,

        # Phase 4: Memory Store
        Kerf.Memory.Supervisor
      ] ++ credential_vault_children() ++ approval_gate_children() ++ [

        # Phase 6: Scheduler
        Kerf.Scheduler.Supervisor,

        # Phase 7: Dashboard
        Kerf.Dashboard.Supervisor
      ] ++ knowledge_base_children() ++ email_triage_children() ++ telegram_children() ++ whatsapp_children() ++ monitor_children()


    opts = [strategy: :one_for_one, name: Kerf.Supervisor]
    Supervisor.start_link(children, opts)
  end


  defp credential_vault_children do
    config = Application.get_env(:exclaw, Kerf.CredentialVault, [])

    if config[:enabled] != false and config[:encryption_key_base] do
      [{Kerf.CredentialVault.Supervisor, []}]
    else
      []
    end
  end

  defp approval_gate_children do
    config = Application.get_env(:exclaw, Kerf.Workflow.ApprovalGate, [])

    if config[:enabled] != false do
      [{Kerf.Workflow.ApprovalGate.Supervisor, []}]
    else
      []
    end
  end

  defp knowledge_base_children do
    [{Kerf.KnowledgeBase.Supervisor, []}]
  end

  defp email_triage_children do
    config = Application.get_env(:exclaw, Kerf.Ingestors.Email.EmailIngestor, [])

    if config[:enabled] do
      [{Kerf.Agents.EmailTriage.Supervisor, []}]
    else
      []
    end
  end

  defp telegram_children do
    config = Application.get_env(:exclaw, Kerf.Channels.Telegram, [])

    if config[:enabled] do
      [{Kerf.Channels.Telegram.Supervisor,
        telegram_opts:
          config
          |> Keyword.put(:name, Kerf.Channels.Telegram)}]
    else
      []
    end
  end

  defp whatsapp_children do
    config = Application.get_env(:exclaw, Kerf.Channels.WhatsApp, [])

    if config[:enabled] do
      [{Kerf.Channels.WhatsApp.Supervisor,
        whatsapp_opts:
          config
          |> Keyword.put(:name, Kerf.Channels.WhatsApp)}]
    else
      []
    end
  end

  defp monitor_children do
    health_config = Application.get_env(:exclaw, Kerf.Monitor.ProcessHealth, [])
    alerting_config = Application.get_env(:exclaw, Kerf.Monitor.Alerting, [])

    [{Kerf.Monitor.Supervisor,
      name: Kerf.Monitor.Supervisor,
      process_health_opts:
        health_config
        |> Keyword.put(:name, Kerf.Monitor.ProcessHealth),
      alerting_opts:
        alerting_config
        |> Keyword.put(:name, Kerf.Monitor.Alerting)}]
  end
end
