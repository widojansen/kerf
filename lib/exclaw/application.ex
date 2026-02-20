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

        # Phase 2: LLM Provider
        ExClaw.LLM.Supervisor,

        # Phase 3: Agent Session
        ExClaw.Agent.Supervisor,

        # Phase 4: Memory Store
        ExClaw.Memory.Supervisor,

        # Phase 6: Scheduler
        ExClaw.Scheduler.Supervisor,

        # Phase 7: Dashboard
        ExClaw.Dashboard.Supervisor
      ] ++ whatsapp_children()

    opts = [strategy: :one_for_one, name: ExClaw.Supervisor]
    Supervisor.start_link(children, opts)
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
