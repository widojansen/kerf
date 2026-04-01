defmodule ExClaw.KnowledgeBase.Chunk do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kb_chunks" do
    belongs_to :document, ExClaw.KnowledgeBase.Document
    field :chunk_index, :integer
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :token_count, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:document_id, :chunk_index, :content, :embedding, :token_count])
    |> validate_required([:document_id, :chunk_index, :content])
    |> foreign_key_constraint(:document_id)
    |> unique_constraint([:document_id, :chunk_index])
  end
end
