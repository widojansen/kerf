defmodule Kerf.Agents.EmailTriage.ActionTaxonomy do
  @moduledoc "Schema for `email_action_taxonomy`. See `Kerf.Agents.EmailTriage.Taxonomy` for the public API."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:value, :string, autogenerate: false}

  schema "email_action_taxonomy" do
    field :accepted, :boolean, default: false
    field :proposed_by, :string
    field :proposed_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :usage_count, :integer, default: 0
    field :description, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    cast(entry, attrs, ~w(value accepted proposed_by proposed_at accepted_at usage_count description)a)
  end
end
