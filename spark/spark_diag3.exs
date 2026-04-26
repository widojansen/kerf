import Ecto.Query

# Check what source_metadata actually contains
doc = from(d in Kerf.KnowledgeBase.Document,
  where: d.source_type == "email",
  order_by: [desc: d.inserted_at],
  limit: 1)
|> Kerf.Repo.one()

IO.puts("--- Sample document source_metadata keys ---")
if doc do
  IO.puts("Title: #{doc.title}")
  IO.puts("Source ID: #{doc.source_id}")
  IO.puts("Source metadata keys: #{inspect(Map.keys(doc.source_metadata))}")
  IO.puts("Source metadata: #{inspect(doc.source_metadata, pretty: true, limit: 2000)}")
else
  IO.puts("No documents")
end

IO.puts("\n--- EmailIngestor config check ---")
config = Application.get_all_env(:exclaw)
  |> Enum.filter(fn {k, _} -> 
    k_str = Atom.to_string(k)
    String.contains?(k_str, "Ingestor") or String.contains?(k_str, "EmailTriage") or String.contains?(k_str, "Gmail")
  end)

IO.puts("Relevant config entries:")
for {key, val} <- config do
  IO.puts("  #{inspect(key)}: #{inspect(val, limit: 200)}")
end
