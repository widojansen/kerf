defmodule ExClaw.Application do
  @moduledoc """
  ExClaw OTP Application.

  Starts only the components that are implemented.
  Components are added incrementally as they are built and tested.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Phase 1: Foundation
      ExClaw.Repo,
      {Registry, keys: :unique, name: ExClaw.SessionRegistry},

      # Phase 1: Security (built first via TDD)
      ExClaw.Security.Supervisor,

      # Phase 2: LLM Provider
      ExClaw.LLM.Supervisor,

      # Phase 3: Agent Session
      ExClaw.Agent.Supervisor

      # Future phases (uncomment as implemented):
      # ExClaw.Config,
      # ExClaw.Memory.Supervisor,
      # ExClaw.Tools.Supervisor,
      # ExClaw.Channels.Supervisor,
      # ExClaw.Scheduler,
    ]

    opts = [strategy: :one_for_one, name: ExClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
