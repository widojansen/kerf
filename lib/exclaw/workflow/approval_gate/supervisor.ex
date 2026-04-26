defmodule Kerf.Workflow.ApprovalGate.Supervisor do
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
    config = Application.get_env(:exclaw, Kerf.Workflow.ApprovalGate, [])

    telegram_config = Application.get_env(:exclaw, Kerf.Channels.Telegram, [])
    telegram_token = config[:telegram_token] || telegram_config[:token]

    default_chat_id = config[:default_chat_id]

    children = [
      {Kerf.Workflow.ApprovalGate.Manager,
       [
         name: Kerf.Workflow.ApprovalGate.Manager,
         telegram_token: telegram_token,
         default_chat_id: default_chat_id,
         default_timeout_ms: config[:default_timeout_ms] || 300_000
       ] ++ Keyword.take(opts, [:telegram_client])},
      {Kerf.Workflow.ApprovalGate.CallbackHandler,
       [
         name: Kerf.Workflow.ApprovalGate.CallbackHandler,
         manager: Kerf.Workflow.ApprovalGate.Manager,
         telegram_token: telegram_token
       ] ++ Keyword.take(opts, [:telegram_client])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
