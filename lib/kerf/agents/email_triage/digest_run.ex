defmodule Kerf.Agents.EmailTriage.DigestRun do
  @moduledoc """
  Audit log for digest cron ticks (Step 13). One row per `DigestWorker.perform/1`
  invocation, regardless of whether a Telegram message was sent.

  Statuses:
    * `"sent"`  — a digest message was successfully delivered; `decision_count > 0`
    * `"empty"` — no undigested rows at cron tick time; no message sent
    * `"failed"` — delivery failed mid-transaction; entire run rolled back (NOT inserted)

  Note: `"failed"` is in the validation enum but the transaction-rollback design
  means failed runs leave no row behind (the worker returns `{:error, _}` to
  Oban for retry). The enum value exists for explicit future use if the design
  evolves toward a post-failure audit row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_statuses ~w(sent failed empty)

  schema "email_digest_runs" do
    field :sent_at, :utc_datetime_usec
    field :decision_count, :integer
    field :status, :string
    field :error, :string
    field :window_start, :utc_datetime_usec
    field :window_end, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :sent_at,
      :decision_count,
      :status,
      :error,
      :window_start,
      :window_end
    ])
    |> validate_required([:sent_at, :decision_count, :status])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
