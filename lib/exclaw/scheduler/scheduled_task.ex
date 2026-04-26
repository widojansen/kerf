defmodule Kerf.Scheduler.ScheduledTask do
  use Ecto.Schema
  import Ecto.Changeset

  schema "scheduled_tasks" do
    field :group_id, :string
    field :prompt, :string
    field :schedule_type, :string
    field :schedule_value, :string
    field :context_mode, :string, default: "isolated"
    field :next_run, :utc_datetime
    field :last_run, :utc_datetime
    field :last_result, :string
    field :status, :string, default: "active"

    timestamps()
  end

  @required_fields ~w(group_id prompt schedule_type)a
  @optional_fields ~w(schedule_value context_mode next_run last_run last_result status)a

  @valid_schedule_types ~w(cron interval once at)
  @valid_statuses ~w(active paused completed)
  @valid_context_modes ~w(group isolated)

  def changeset(task, attrs) do
    task
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:schedule_type, @valid_schedule_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:context_mode, @valid_context_modes)
    |> validate_schedule_value_required()
    |> validate_schedule_value()
  end

  defp validate_schedule_value_required(changeset) do
    schedule_type = get_field(changeset, :schedule_type)

    if schedule_type in ["cron", "interval", "at"] do
      validate_required(changeset, [:schedule_value])
    else
      changeset
    end
  end

  defp validate_schedule_value(changeset) do
    schedule_type = get_field(changeset, :schedule_type)
    schedule_value = get_field(changeset, :schedule_value)

    case {schedule_type, schedule_value} do
      {"cron", value} when is_binary(value) ->
        case Crontab.CronExpression.Parser.parse(value) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :schedule_value, "is not a valid cron expression")
        end

      {"interval", value} when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> changeset
          _ -> add_error(changeset, :schedule_value, "must be a positive integer (milliseconds)")
        end

      {"at", value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _, _} -> changeset
          {:error, _} -> add_error(changeset, :schedule_value, "is not a valid ISO-8601 datetime")
        end

      {"once", _} ->
        changeset

      _ ->
        changeset
    end
  end
end
