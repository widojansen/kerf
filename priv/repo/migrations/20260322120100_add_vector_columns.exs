defmodule ExClaw.Repo.Migrations.AddVectorColumns do
  use Ecto.Migration

  def change do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      # Embedding column on messages for semantic search over conversation history
      alter table(:messages) do
        add :embedding, :vector, size: 1024
      end

      # Embedding column on memories for semantic fact retrieval
      alter table(:memories) do
        add :embedding, :vector, size: 1024
      end

      # HNSW index for fast approximate nearest neighbor search
      create index(:messages, ["embedding vector_cosine_ops"], using: :hnsw, name: :messages_embedding_idx)
      create index(:memories, ["embedding vector_cosine_ops"], using: :hnsw, name: :memories_embedding_idx)
    end
  end
end
