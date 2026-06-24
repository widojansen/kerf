defmodule Kerf.ServiceHealth.State do
  @moduledoc """
  Ecto schema for the `monitoring_state` table — the single-row (per target)
  state machine backing `AlertDecision` + `AlertState`. See
  `docs/specs/SPEC_02_ALERT_STATE_MACHINE.md`.

  Module name (`State`) deliberately differs from the table name
  (`monitoring_state`): the table is a data-contract object referenced across
  Specs 2–4 and the Spec-4 cutover. Do NOT rename the table to `state`.

  `last_alert_status` stores the decision atom as a string; the schema boundary
  converts (`status_to_string/1`, `status_to_atom/1`). `last_alert_time` is a
  real `utc_datetime_usec` (Spec 4 converts the legacy Python Unix-epoch float
  via `DateTime.from_unix/2`). This is a state-machine table, so it carries both
  `inserted_at` and `updated_at` (KERF_CONVENTIONS).

  NOTE: the `create_monitoring_state` migration is deferred to the GREEN commit
  (it must run for the schema tests to pass; a raising skeleton would abort
  `ecto.migrate`). At RED the table does not yet exist.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "monitoring_state" do
    field :target, :string
    field :last_alert_status, :string
    field :last_alert_time, :utc_datetime_usec
    field :consecutive_healthy, :integer, default: 0
    field :consecutive_failures, :integer, default: 0

    timestamps()
  end

  @known_statuses ~w(critical anomaly warning recovered healthy)

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :target,
      :last_alert_status,
      :last_alert_time,
      :consecutive_healthy,
      :consecutive_failures
    ])
    |> validate_required([:target])
    |> validate_number(:consecutive_healthy, greater_than_or_equal_to: 0)
    |> validate_number(:consecutive_failures, greater_than_or_equal_to: 0)
    |> validate_inclusion(:last_alert_status, @known_statuses)
    |> unique_constraint(:target)
  end

  @doc "Schema boundary: decision reason atom -> stored string. `nil` passes through."
  @spec status_to_string(atom() | nil) :: String.t() | nil
  def status_to_string(nil), do: nil
  def status_to_string(status) when is_atom(status), do: Atom.to_string(status)

  @doc "Schema boundary: stored string -> decision reason atom. `nil` passes through."
  @spec status_to_atom(String.t() | nil) :: atom() | nil
  def status_to_atom(nil), do: nil
  def status_to_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
