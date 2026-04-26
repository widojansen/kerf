defmodule Kerf.Monitor.TelemetryEvent do
  @moduledoc """
  Ecto schema for the telemetry_events table.

  Stores telemetry events (LLM calls, process health, VM metrics) with
  JSONB measurements and metadata columns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "telemetry_events" do
    field :event_name, :string
    field :measurements, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_name, :measurements, :metadata])
    |> validate_required([:event_name])
  end
end
