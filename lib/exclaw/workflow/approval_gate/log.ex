defmodule Kerf.Workflow.ApprovalGate.Log do
  @moduledoc """
  Ecto schema for the approval gate audit log.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kerf.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "approval_gate_log" do
    field :request_id, :string
    field :agent_module, :string
    field :action, :string
    field :description, :string
    field :context, :map, default: %{}
    field :decision, :string
    field :decided_by, :string
    field :rule_id, :binary_id
    field :telegram_message_id, :integer
    field :chat_id, :integer
    field :requested_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :timeout_ms, :integer
  end

  def log_request(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :request_id, :agent_module, :action, :description, :context,
      :chat_id, :requested_at, :timeout_ms, :telegram_message_id
    ])
    |> validate_required([:request_id, :agent_module, :action, :requested_at, :timeout_ms])
    |> Repo.insert()
  end

  def log_decision(request_id, decision, decided_by, opts \\ []) do
    case Repo.get_by(__MODULE__, request_id: request_id) do
      nil -> {:error, :not_found}
      log ->
        log
        |> cast(
          %{
            decision: decision,
            decided_by: to_string(decided_by),
            decided_at: DateTime.utc_now(),
            rule_id: opts[:rule_id],
            telegram_message_id: opts[:telegram_message_id]
          },
          [:decision, :decided_by, :decided_at, :rule_id, :telegram_message_id]
        )
        |> Repo.update()
    end
  end
end
