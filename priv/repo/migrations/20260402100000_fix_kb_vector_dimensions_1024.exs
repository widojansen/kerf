defmodule ExClaw.Repo.Migrations.FixKbVectorDimensions1024 do
  use Ecto.Migration

  def up do
    # bge-m3 produces 1024-dim vectors, not 768.
    # Existing messages/memories columns are already 1024. Match them.

    # kb_chunks: drop HNSW index, alter column, recreate index
    execute "DROP INDEX IF EXISTS idx_kbc_embedding"
    execute "ALTER TABLE kb_chunks ALTER COLUMN embedding TYPE vector(1024)"

    execute """
    CREATE INDEX idx_kbc_embedding ON kb_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    # kb_interests: alter column (no index to rebuild)
    execute "ALTER TABLE kb_interests ALTER COLUMN embedding TYPE vector(1024)"
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_kbc_embedding"
    execute "ALTER TABLE kb_chunks ALTER COLUMN embedding TYPE vector(768)"

    execute """
    CREATE INDEX idx_kbc_embedding ON kb_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    execute "ALTER TABLE kb_interests ALTER COLUMN embedding TYPE vector(768)"
  end
end
