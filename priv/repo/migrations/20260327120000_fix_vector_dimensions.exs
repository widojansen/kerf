defmodule Kerf.Repo.Migrations.FixVectorDimensions do
  use Ecto.Migration

  def up do
    # nomic-embed-text v1.5 produces 768-dim vectors, not 1024
    # Drop HNSW indexes first, then alter column type, then recreate indexes
    execute "DROP INDEX IF EXISTS messages_embedding_idx"
    execute "DROP INDEX IF EXISTS memories_embedding_idx"

    execute "ALTER TABLE messages ALTER COLUMN embedding TYPE vector(768)"
    execute "ALTER TABLE memories ALTER COLUMN embedding TYPE vector(768)"

    execute "CREATE INDEX messages_embedding_idx ON messages USING hnsw (embedding vector_cosine_ops)"
    execute "CREATE INDEX memories_embedding_idx ON memories USING hnsw (embedding vector_cosine_ops)"
  end

  def down do
    execute "DROP INDEX IF EXISTS messages_embedding_idx"
    execute "DROP INDEX IF EXISTS memories_embedding_idx"

    execute "ALTER TABLE messages ALTER COLUMN embedding TYPE vector(1024)"
    execute "ALTER TABLE memories ALTER COLUMN embedding TYPE vector(1024)"

    execute "CREATE INDEX messages_embedding_idx ON messages USING hnsw (embedding vector_cosine_ops)"
    execute "CREATE INDEX memories_embedding_idx ON memories USING hnsw (embedding vector_cosine_ops)"
  end
end
