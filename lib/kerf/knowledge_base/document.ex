defmodule Kerf.KnowledgeBase.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_source_types ~w(email pdf youtube rss book podcast)

  schema "kb_documents" do
    field :source_type, :string
    field :source_id, :string
    field :source_metadata, :map, default: %{}
    field :title, :string
    field :raw_text, :string
    field :content_hash, :string
    field :processed_at, :utc_datetime_usec

    has_many :chunks, Kerf.KnowledgeBase.Chunk
    has_many :feedback, Kerf.KnowledgeBase.Feedback

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:source_type, :source_id, :source_metadata, :title, :raw_text, :content_hash, :processed_at])
    |> validate_required([:source_type])
    |> validate_inclusion(:source_type, @valid_source_types)
    |> unique_constraint([:source_type, :source_id])
  end
end
