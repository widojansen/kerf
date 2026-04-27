defmodule Kerf.Repo.Migrations.CreateKbDocuments do
  use Ecto.Migration

  def change do
    create table(:kb_documents, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :source_type, :string, null: false, size: 50
      add :source_id, :string, size: 500
      add :source_metadata, :map, default: %{}
      add :title, :text
      add :raw_text, :text
      add :content_hash, :string, size: 64
      add :processed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:kb_documents, [:source_type, :source_id])
    create index(:kb_documents, [:source_type])
    create index(:kb_documents, [:source_id])
    create index(:kb_documents, [:content_hash])
    create index(:kb_documents, [:inserted_at])
    create index(:kb_documents, [:source_metadata], using: "GIN")
  end
end
