import Ecto.Query

triaged_ids = from(f in ExClaw.KnowledgeBase.Feedback, where: f.feedback_type == "triage", select: f.document_id)
untriaged = from(d in ExClaw.KnowledgeBase.Document,
  where: d.source_type == "email" and d.id not in subquery(triaged_ids),
  select: %{sender: d.source_metadata["sender"], title: d.title})
|> ExClaw.Repo.all()

patterns = from(s in ExClaw.KnowledgeBase.EmailSender,
  where: not is_nil(s.match_pattern),
  select: s.match_pattern)
|> ExClaw.Repo.all()

known_emails = from(s in ExClaw.KnowledgeBase.EmailSender,
  where: not is_nil(s.classification_override),
  select: s.email)
|> ExClaw.Repo.all()

unmatched = Enum.filter(untriaged, fn %{sender: sender} ->
  sender = sender || ""
  lower = String.downcase(sender)
  not Enum.any?(known_emails, &(&1 == lower)) and
  not Enum.any?(patterns, fn p -> String.contains?(lower, String.downcase(p)) end)
end)

IO.puts("Unmatched senders (#{length(unmatched)}/#{length(untriaged)}):")
unmatched
|> Enum.map(& &1.sender)
|> Enum.uniq()
|> Enum.sort()
|> Enum.each(fn s -> IO.puts("  #{s}") end)

IO.puts("\nWith subjects:")
unmatched
|> Enum.uniq_by(& &1.sender)
|> Enum.sort_by(& &1.sender)
|> Enum.each(fn %{sender: s, title: t} -> IO.puts("  #{s} -- #{t}") end)
