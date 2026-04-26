import Ecto.Query

IO.puts("--- Recent email samples (last 10) ---")
recent_emails = from(d in Kerf.KnowledgeBase.Document,
  where: d.source_type == "email",
  order_by: [desc: d.inserted_at],
  limit: 10,
  select: %{
    id: d.id,
    source_id: d.source_id,
    title: d.title,
    source_metadata: d.source_metadata,
    inserted_at: d.inserted_at
  })
|> Kerf.Repo.all()

if length(recent_emails) > 0 do
  for doc <- recent_emails do
    from = get_in(doc.source_metadata, ["from"]) || "unknown"
    subject = doc.title || get_in(doc.source_metadata, ["subject"]) || "no subject"
    IO.puts("  [#{doc.inserted_at}] #{from}")
    IO.puts("    Subject: #{subject}")
  end
else
  IO.puts("  No emails in production DB")
end

# Check chunks
IO.puts("\n--- KB Chunks status ---")
total_chunks = Kerf.Repo.aggregate(Kerf.KnowledgeBase.Chunk, :count)
IO.puts("Total chunks: #{total_chunks}")
chunks_with_embedding = Kerf.Repo.aggregate(
  from(c in Kerf.KnowledgeBase.Chunk, where: not is_nil(c.embedding)),
  :count
)
IO.puts("Chunks with embeddings: #{chunks_with_embedding}")

# Check the EmailTriage module's triage_document function
IO.puts("\n--- EmailTriage pipeline check ---")
IO.puts("Checking what triage_document actually does...")

# Try to get a document with preloaded chunks to test
doc = from(d in Kerf.KnowledgeBase.Document,
  where: d.source_type == "email",
  order_by: [desc: d.inserted_at],
  limit: 1,
  preload: [:chunks])
|> Kerf.Repo.one()

if doc do
  from = get_in(doc.source_metadata, ["from"]) || "unknown"
  IO.puts("Test document: #{from} — #{doc.title}")
  IO.puts("  Chunks: #{length(doc.chunks)}")
  has_embeddings = Enum.count(doc.chunks, & &1.embedding != nil)
  IO.puts("  Chunks with embeddings: #{has_embeddings}")
else
  IO.puts("No documents to test with")
end

IO.puts("\nDONE")
