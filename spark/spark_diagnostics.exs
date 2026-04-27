import Ecto.Query

IO.puts("=" |> String.duplicate(60))
IO.puts("EMAIL TRIAGE DIAGNOSTIC — Part 1 (PRODUCTION)")
IO.puts("=" |> String.duplicate(60))

# 1.1 Interest Embeddings Status
IO.puts("\n--- 1.1 Interest Embeddings Status ---")
total_interests = Kerf.Repo.aggregate(Kerf.KnowledgeBase.Interest, :count)
IO.puts("Total interests: #{total_interests}")

interests_with_embedding = Kerf.Repo.aggregate(
  from(i in Kerf.KnowledgeBase.Interest, where: not is_nil(i.embedding)),
  :count
)
IO.puts("Interests with embeddings: #{interests_with_embedding}")

interest_details = from(i in Kerf.KnowledgeBase.Interest,
  select: %{topic: i.topic, has_embedding: not is_nil(i.embedding), enabled: i.enabled, weight: i.weight})
|> Kerf.Repo.all()

if length(interest_details) > 0 do
  for detail <- interest_details do
    status = if detail.has_embedding, do: "YES", else: "NULL"
    enabled = if detail.enabled, do: "", else: " [DISABLED]"
    IO.puts("  [#{status}] #{detail.topic} (weight=#{detail.weight})#{enabled}")
  end
else
  IO.puts("  ** NO INTERESTS FOUND — interest matching is completely non-functional **")
end

# 1.2 KB Documents & Triage State
IO.puts("\n--- 1.2 KB Documents & Triage State ---")
total_emails = from(d in Kerf.KnowledgeBase.Document, where: d.source_type == "email")
|> Kerf.Repo.aggregate(:count)
IO.puts("Total email documents in KB: #{total_emails}")

total_docs = Kerf.Repo.aggregate(Kerf.KnowledgeBase.Document, :count)
IO.puts("Total documents (all types): #{total_docs}")

if total_emails > 0 do
  triaged_emails = from(f in Kerf.KnowledgeBase.Feedback,
    join: d in Kerf.KnowledgeBase.Document, on: f.document_id == d.id,
    where: d.source_type == "email")
  |> Kerf.Repo.aggregate(:count)
  IO.puts("Emails with triage feedback: #{triaged_emails}")

  emails_with_feedback = from(f in Kerf.KnowledgeBase.Feedback, select: f.document_id)
  untriaged_emails = from(d in Kerf.KnowledgeBase.Document,
    where: d.source_type == "email" and d.id not in subquery(emails_with_feedback))
  |> Kerf.Repo.aggregate(:count)
  IO.puts("Emails WITHOUT triage feedback (stuck backlog): #{untriaged_emails}")
end

total_feedback = Kerf.Repo.aggregate(Kerf.KnowledgeBase.Feedback, :count)
IO.puts("Total feedback records (all types): #{total_feedback}")

# 1.3 Email Sender Table
IO.puts("\n--- 1.3 Email Sender Table ---")
total_senders = Kerf.Repo.aggregate(Kerf.KnowledgeBase.EmailSender, :count)
IO.puts("Total senders tracked: #{total_senders}")

priority_senders = from(s in Kerf.KnowledgeBase.EmailSender, where: s.is_priority == true)
|> Kerf.Repo.all()
IO.puts("Priority senders (#{length(priority_senders)}):")
for s <- priority_senders do
  override = if s.classification_override, do: " [#{s.classification_override}]", else: ""
  pattern = if s.match_pattern, do: " pattern=#{s.match_pattern}", else: ""
  IO.puts("  * #{s.email}#{override}#{pattern}")
end

top_senders = from(s in Kerf.KnowledgeBase.EmailSender,
  order_by: [desc: s.total_interactions],
  limit: 20,
  select: %{email: s.email, interactions: s.total_interactions, priority: s.is_priority, total_emails: s.total_emails})
|> Kerf.Repo.all()
IO.puts("Top 20 senders by interaction count:")
for s <- top_senders do
  flag = if s.priority, do: "*", else: " "
  IO.puts("  #{flag} #{s.email} (#{s.interactions} interactions, #{s.total_emails} emails)")
end

# 1.5 Gmail Labels — check GmailClient available functions
IO.puts("\n--- 1.5 Gmail Label State ---")
IO.puts("GmailClient has no list_labels — available: fetch_new, search, get_message, resolve_label, apply_labels, modify_message")
IO.puts("Cannot enumerate labels without a list_labels API call.")

# 1.7 EmailIngestor Status
IO.puts("\n--- 1.7 EmailIngestor Status ---")
case Process.whereis(Kerf.Ingestors.Email.EmailIngestor) do
  nil ->
    IO.puts("EmailIngestor is NOT running")
  pid ->
    IO.puts("EmailIngestor PID: #{inspect(pid)}, alive: #{Process.alive?(pid)}")
    try do
      state = :sys.get_state(pid, 5000)
      IO.puts("State: #{inspect(state, pretty: true, limit: 1000)}")
    catch
      :exit, reason -> IO.puts("Could not get state: #{inspect(reason)}")
    end
end

IO.puts("\n--- 1.7b: EmailTriage GenServer Status ---")
case Process.whereis(Kerf.Agents.EmailTriage.EmailTriage) do
  nil ->
    IO.puts("EmailTriage GenServer is NOT running")
  pid ->
    IO.puts("EmailTriage PID: #{inspect(pid)}, alive: #{Process.alive?(pid)}")
    try do
      state = :sys.get_state(pid, 5000)
      IO.puts("State: #{inspect(state, pretty: true, limit: 1000)}")
    catch
      :exit, reason -> IO.puts("Could not get state: #{inspect(reason)}")
    end
end

# Recent email samples
IO.puts("\n--- Recent email samples (last 10) ---")
recent_emails = from(d in Kerf.KnowledgeBase.Document,
  where: d.source_type == "email",
  order_by: [desc: d.inserted_at],
  limit: 10,
  select: %{
    id: d.id,
    source_id: d.source_id,
    metadata: d.metadata,
    inserted_at: d.inserted_at
  })
|> Kerf.Repo.all()

if length(recent_emails) > 0 do
  for doc <- recent_emails do
    from = get_in(doc.metadata, ["from"]) || "unknown"
    subject = get_in(doc.metadata, ["subject"]) || "no subject"
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

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("DIAGNOSTICS COMPLETE")
IO.puts(String.duplicate("=", 60))
