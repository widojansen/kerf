defmodule ExClaw.Repo.Migrations.CreateApprovalGateLog do
  use Ecto.Migration

  def change do
    create table(:approval_gate_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :request_id, :string, null: false
      add :agent_module, :string, null: false
      add :action, :string, null: false
      add :description, :text
      add :context, :map, default: %{}
      add :decision, :string
      add :decided_by, :string
      add :rule_id, references(:approval_gate_auto_rules, type: :uuid, on_delete: :nilify_all)
      add :telegram_message_id, :integer
      add :chat_id, :bigint
      add :requested_at, :utc_datetime_usec, null: false
      add :decided_at, :utc_datetime_usec
      add :timeout_ms, :integer, null: false
    end

    create index(:approval_gate_log, [:agent_module], name: "idx_agl_agent")
    create index(:approval_gate_log, [:requested_at], name: "idx_agl_requested")

    create index(:approval_gate_log, [:decision],
      where: "decision IS NULL",
      name: "idx_agl_pending"
    )
  end
end
