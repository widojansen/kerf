defmodule ExClaw.Repo.Migrations.CreateApprovalGateAutoRules do
  use Ecto.Migration

  def change do
    create table(:approval_gate_auto_rules, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_module, :string, null: false
      add :action, :string, null: false
      add :context_pattern, :map, default: %{}, null: false
      add :decision, :string, default: "approve", null: false
      add :enabled, :boolean, default: true, null: false
      add :times_matched, :integer, default: 0, null: false
      add :last_matched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:approval_gate_auto_rules, [:agent_module, :action],
      where: "enabled = TRUE",
      name: "idx_agar_agent_action"
    )
  end
end
