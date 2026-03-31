defmodule ExClaw.Workflow.ApprovalGate.Supervisor do
  @moduledoc """
  Supervisor for the ApprovalGate subsystem.
  Starts the Manager and CallbackHandler.
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:exclaw, ExClaw.Workflow.ApprovalGate, [])

    telegram_config = Application.get_env(:exclaw, ExClaw.Channels.Telegram, [])
    telegram_token = config[:telegram_token] || telegram_config[:token]

    default_chat_id = config[:default_chat_id]

    children = [
      {ExClaw.Workflow.ApprovalGate.Manager,
       [
         name: ExClaw.Workflow.ApprovalGate.Manager,
         telegram_token: telegram_token,
         default_chat_id: default_chat_id,
         default_timeout_ms: config[:default_timeout_ms] || 300_000
       ] ++ Keyword.take(opts, [:telegram_client])},
      {ExClaw.Workflow.ApprovalGate.CallbackHandler,
       [
         name: ExClaw.Workflow.ApprovalGate.CallbackHandler,
         manager: ExClaw.Workflow.ApprovalGate.Manager,
         telegram_token: telegram_token
       ] ++ Keyword.take(opts, [:telegram_client])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
