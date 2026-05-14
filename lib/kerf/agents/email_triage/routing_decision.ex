defmodule Kerf.Agents.EmailTriage.RoutingDecision do
  @moduledoc """
  Per-email routing decision (audit log) — one row per Router job, recording
  which rule fired and what action was taken.

  Backs the `email_routing_decisions` table (migration 20260512120548).

  Insert-only by design (`timestamps(updated_at: false)`); rows are never
  mutated. Cascades on `email_triage` delete via the migration's FK
  `on_delete: :delete_all`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_actions ~w(telegram_ping telegram_digest silent)

  schema "email_routing_decisions" do
    belongs_to :triage_record,
               Kerf.Agents.EmailTriage.TriageRecord,
               type: :binary_id,
               foreign_key: :email_triage_id

    field :rule_name, :string
    field :action_taken, :string
    field :routing_config_version, :string

    # Step 13: drained marker for the digest worker. NULL means "queued for
    # digest"; non-NULL means "included in a digest run at this timestamp."
    field :digested_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:email_triage_id, :rule_name, :action_taken, :routing_config_version])
    |> validate_required([:email_triage_id, :rule_name, :action_taken, :routing_config_version])
    |> validate_inclusion(:action_taken, @valid_actions)
    |> foreign_key_constraint(:email_triage_id)
  end
end
