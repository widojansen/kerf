defmodule Kerf.Memory.Fact do
  use Ecto.Schema
  import Ecto.Changeset

  schema "memories" do
    field :group_id, :string
    field :key, :string
    field :value, :string
    field :source, :string
    field :embedding, Pgvector.Ecto.Vector

    timestamps()
  end

  @required_fields ~w(group_id key value)a
  @optional_fields ~w(source embedding)a

  def changeset(fact, attrs) do
    fact
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:group_id, :key])
  end
end
