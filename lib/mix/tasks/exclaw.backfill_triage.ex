defmodule Mix.Tasks.Exclaw.BackfillTriage do
  @shortdoc "Triage emails in the KB that have no feedback records"
  @moduledoc """
  Runs the email triage pipeline on emails that were ingested but never triaged.

  ## Usage

      # Preview what would be triaged
      mix exclaw.backfill_triage --dry-run -n 20

      # Triage 10 emails (start small)
      mix exclaw.backfill_triage -n 10

      # Triage all untriaged
      mix exclaw.backfill_triage -n 1000
  """
  use Mix.Task

  import Ecto.Query

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [limit: :integer, dry_run: :boolean],
        aliases: [n: :limit]
      )

    limit = Keyword.get(opts, :limit, 10)
    dry_run = Keyword.get(opts, :dry_run, false)

    alias ExClaw.KnowledgeBase.{Document, Feedback}
    alias ExClaw.Agents.EmailTriage.EmailTriage

    triaged_ids = from(f in Feedback, where: f.feedback_type == "triage", select: f.document_id)

    untriaged =
      from(d in Document,
        where: d.source_type == "email" and d.id not in subquery(triaged_ids),
        order_by: [desc: d.inserted_at],
        limit: ^limit
      )
      |> ExClaw.Repo.all()

    total_untriaged =
      from(d in Document,
        where: d.source_type == "email" and d.id not in subquery(triaged_ids)
      )
      |> ExClaw.Repo.aggregate(:count)

    IO.puts("Found #{total_untriaged} untriaged emails (processing #{min(limit, total_untriaged)})")

    if dry_run do
      for doc <- untriaged do
        from = doc.source_metadata["sender"] || "unknown"
        subject = doc.title || "no subject"
        IO.puts("  #{from} -- #{subject}")
      end
    else
      triage_name = ExClaw.Agents.EmailTriage.EmailTriage

      case Process.whereis(triage_name) do
        nil ->
          IO.puts("ERROR: EmailTriage GenServer is not running. Start ExClaw first.")

        _pid ->
          for {doc, i} <- Enum.with_index(untriaged, 1) do
            from = doc.source_metadata["sender"] || "unknown"
            subject = doc.title || "no subject"
            IO.puts("\n[#{i}/#{length(untriaged)}] Triaging: #{from} -- #{subject}")

            start = System.monotonic_time(:millisecond)
            result = EmailTriage.triage(triage_name, [doc.id])
            elapsed = System.monotonic_time(:millisecond) - start

            case result do
              {:ok, [info]} ->
                IO.puts("  OK #{info.classification.category} p#{info.final_priority} (#{elapsed}ms)")

              {:ok, []} ->
                IO.puts("  SKIP no classification (#{elapsed}ms)")

              {:error, reason} ->
                IO.puts("  ERROR #{inspect(reason)} (#{elapsed}ms)")
            end
          end
      end
    end
  end
end
