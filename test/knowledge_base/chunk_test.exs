defmodule Kerf.KnowledgeBase.ChunkTest do
  use Kerf.DataCase

  alias Kerf.KnowledgeBase.{Document, Chunk}

  setup do
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{
          source_type: "email",
          source_id: "msg_chunk_test"
        })
      )

    %{doc: doc}
  end

  describe "changeset/2" do
    test "valid with required fields", %{doc: doc} do
      cs =
        Chunk.changeset(%Chunk{}, %{
          document_id: doc.id,
          chunk_index: 0,
          content: "Hello world"
        })

      assert cs.valid?
    end

    test "requires document_id" do
      cs = Chunk.changeset(%Chunk{}, %{chunk_index: 0, content: "text"})
      refute cs.valid?
      assert %{document_id: ["can't be blank"]} = errors_on(cs)
    end

    test "requires content" do
      cs = Chunk.changeset(%Chunk{}, %{document_id: Ecto.UUID.generate(), chunk_index: 0})
      refute cs.valid?
      assert %{content: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "insert" do
    test "inserts a chunk linked to document", %{doc: doc} do
      attrs = %{document_id: doc.id, chunk_index: 0, content: "First chunk", token_count: 5}
      assert {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))
      assert chunk.document_id == doc.id
      assert chunk.chunk_index == 0
    end

    test "enforces unique document_id + chunk_index", %{doc: doc} do
      attrs = %{document_id: doc.id, chunk_index: 0, content: "chunk a"}
      {:ok, _} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))

      assert {:error, cs} =
               Repo.insert(
                 Chunk.changeset(%Chunk{}, %{document_id: doc.id, chunk_index: 0, content: "chunk b"})
               )

      assert %{document_id: ["has already been taken"]} = errors_on(cs)
    end

    test "cascade deletes chunks when document deleted", %{doc: doc} do
      {:ok, _} =
        Repo.insert(Chunk.changeset(%Chunk{}, %{document_id: doc.id, chunk_index: 0, content: "c1"}))

      {:ok, _} =
        Repo.insert(Chunk.changeset(%Chunk{}, %{document_id: doc.id, chunk_index: 1, content: "c2"}))

      Repo.delete!(doc)
      assert Repo.all(Chunk) == []
    end

    test "stores embedding vector", %{doc: doc} do
      embedding = Pgvector.new(List.duplicate(0.1, 1024))

      attrs = %{
        document_id: doc.id,
        chunk_index: 0,
        content: "vector chunk",
        embedding: embedding
      }

      assert {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))
      reloaded = Repo.get!(Chunk, chunk.id)
      assert Pgvector.to_list(reloaded.embedding) |> length() == 1024
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
