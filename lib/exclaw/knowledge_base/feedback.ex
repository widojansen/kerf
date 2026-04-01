defmodule ExClaw.KnowledgeBase.Feedback do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kb_feedback" do
    belongs_to :document, ExClaw.KnowledgeBase.Document
    field :feedback_type, :string
    field :decision, :string
    field :context, :map, default: %{}
    field :source, :string, default: "telegram"

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [:document_id, :feedback_type, :decision, :context, :source])
    |> validate_required([:feedback_type, :decision])
    |> foreign_key_constraint(:document_id)
  end
end
