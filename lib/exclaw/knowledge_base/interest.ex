defmodule Kerf.KnowledgeBase.Interest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kb_interests" do
    field :topic, :string
    field :keywords, {:array, :string}, default: []
    field :weight, :float, default: 1.0
    field :embedding, Pgvector.Ecto.Vector
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(interest, attrs) do
    interest
    |> cast(attrs, [:topic, :keywords, :weight, :embedding, :enabled])
    |> validate_required([:topic])
    |> unique_constraint(:topic)
  end
end
