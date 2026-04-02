defmodule ExClaw.Repo.Migrations.CreateKbChunks do
  use Ecto.Migration

  def change do
    create table(:kb_chunks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :document_id, references(:kb_documents, type: :uuid, on_delete: :delete_all),
        null: false
      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      add :embedding, :vector, size: 1024
      add :token_count, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:kb_chunks, [:document_id, :chunk_index])
    create index(:kb_chunks, [:document_id])

    execute(
      "CREATE INDEX idx_kbc_embedding ON kb_chunks USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)",
      "DROP INDEX IF EXISTS idx_kbc_embedding"
    )
  end
end
