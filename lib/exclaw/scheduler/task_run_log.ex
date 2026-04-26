defmodule Kerf.Scheduler.TaskRunLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_run_logs" do
    field :task_id, :integer
    field :started_at, :utc_datetime
    field :duration_ms, :integer
    field :status, :string
    field :result, :string
    field :error, :string

    timestamps()
  end

  @required_fields ~w(task_id started_at duration_ms status)a
  @optional_fields ~w(result error)a

  @valid_statuses ~w(success error)

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
