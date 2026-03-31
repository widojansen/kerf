defmodule ExClaw.Application do
  @moduledoc """
  ExClaw OTP Application.

  Starts only the components that are implemented.
  Components are added incrementally as they are built and tested.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Phase 1: Foundation
        ExClaw.Repo,
        {Phoenix.PubSub, name: ExClaw.PubSub},
        {Registry, keys: :unique, name: ExClaw.SessionRegistry},
        # Task.Supervisor for async channel message handling
        {Task.Supervisor, name: ExClaw.TaskSupervisor},

        # Phase 8: Telemetry (started early so all modules can emit)
        {ExClaw.Telemetry.Supervisor,
         logger_opts:
           Application.get_env(:exclaw, ExClaw.Telemetry.Logger, [])
           |> Keyword.put(:name, ExClaw.Telemetry.Logger)},

        # Phase 1: Security (built first via TDD)
        ExClaw.Security.Supervisor,

        # Phase 9: Container Manager (Docker sandbox per group)
        {ExClaw.Container.Supervisor,
         manager_opts:
           Application.get_env(:exclaw, ExClaw.Container.Manager, [])
           |> Keyword.put(:name, ExClaw.Container.Manager)},

        # Phase 11: Tool Registry (ETS-backed, auto-registers builtins)
        {ExClaw.Tools.Registry, name: ExClaw.Tools.Registry, register_builtins: true},

        # Phase 2: LLM Provider
        ExClaw.LLM.Supervisor,

        # Phase 3: Agent Session
        ExClaw.Agent.Supervisor,

        # Phase 4: Memory Store
        ExClaw.Memory.Supervisor
      ] ++ credential_vault_children() ++ approval_gate_children() ++ [

        # Phase 6: Scheduler
        ExClaw.Scheduler.Supervisor,

        # Phase 7: Dashboard
        ExClaw.Dashboard.Supervisor
      ] ++ telegram_children() ++ whatsapp_children()


    opts = [strategy: :one_for_one, name: ExClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end


  defp credential_vault_children do
    config = Application.get_env(:exclaw, ExClaw.CredentialVault, [])

    if config[:enabled] != false and config[:encryption_key_base] do
      [{ExClaw.CredentialVault.Supervisor, []}]
    else
      []
    end
  end

  defp approval_gate_children do
    config = Application.get_env(:exclaw, ExClaw.Workflow.ApprovalGate, [])

    if config[:enabled] != false do
      [{ExClaw.Workflow.ApprovalGate.Supervisor, []}]
    else
      []
    end
  end

  defp telegram_children do
    config = Application.get_env(:exclaw, ExClaw.Channels.Telegram, [])

    if config[:enabled] do
      [{ExClaw.Channels.Telegram.Supervisor,
        telegram_opts:
          config
          |> Keyword.put(:name, ExClaw.Channels.Telegram)}]
    else
      []
    end
  end

  defp whatsapp_children do
    config = Application.get_env(:exclaw, ExClaw.Channels.WhatsApp, [])

    if config[:enabled] do
      [{ExClaw.Channels.WhatsApp.Supervisor,
        whatsapp_opts:
          config
          |> Keyword.put(:name, ExClaw.Channels.WhatsApp)}]
    else
      []
    end
  end
end
