defmodule Mix.Tasks.Exclaw.BackfillTriage do
  @shortdoc "Triage emails in the KB that have no feedback records"
  @moduledoc """
  Runs the email triage pipeline on emails that were ingested but never triaged.
  Starts its own EmailTriage GenServer — does not require the release to be running.

  ## Usage

      # Preview what would be triaged
      MIX_ENV=prod mix exclaw.backfill_triage --dry-run -n 20

      # Triage 10 emails (start small)
      MIX_ENV=prod mix exclaw.backfill_triage -n 10

      # Triage all untriaged
      MIX_ENV=prod mix exclaw.backfill_triage -n 1000
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

    alias Kerf.KnowledgeBase.{Document, Feedback}
    alias Kerf.Agents.EmailTriage.EmailTriage

    triaged_ids = from(f in Feedback, where: f.feedback_type == "triage", select: f.document_id)

    untriaged =
      from(d in Document,
        where: d.source_type == "email" and d.id not in subquery(triaged_ids),
        order_by: [desc: d.inserted_at],
        limit: ^limit
      )
      |> Kerf.Repo.all()

    total_untriaged =
      from(d in Document,
        where: d.source_type == "email" and d.id not in subquery(triaged_ids)
      )
      |> Kerf.Repo.aggregate(:count)

    IO.puts("Found #{total_untriaged} untriaged emails (processing #{min(limit, total_untriaged)})")

    if dry_run do
      for doc <- untriaged do
        from = doc.source_metadata["sender"] || "unknown"
        subject = doc.title || "no subject"
        IO.puts("  #{from} -- #{subject}")
      end
    else
      # Start a local EmailTriage GenServer for this backfill run
      triage_name = :"backfill_triage_#{System.unique_integer([:positive])}"

      triage_config = Application.get_env(:exclaw, Kerf.Agents.EmailTriage, [])

      {:ok, _pid} =
        EmailTriage.start_link(
          name: triage_name,
          repo: Kerf.Repo,
          interest_threshold: Keyword.get(triage_config, :interest_threshold, 0.5),
          high_priority_threshold: Keyword.get(triage_config, :high_priority_threshold, 4)
        )

      IO.puts("Started local EmailTriage (no Gmail/Telegram — classify + feedback only)\n")

      for {doc, i} <- Enum.with_index(untriaged, 1) do
        from = doc.source_metadata["sender"] || "unknown"
        subject = doc.title || "no subject"
        IO.puts("[#{i}/#{length(untriaged)}] #{from} -- #{subject}")

        start = System.monotonic_time(:millisecond)
        result = EmailTriage.triage(triage_name, [doc.id])
        elapsed = System.monotonic_time(:millisecond) - start

        case result do
          {:ok, [info]} ->
            source = if info.classification[:source] == :fast_classifier, do: "FAST", else: "LLM"
            IO.puts("  #{source} #{info.classification.category} p#{info.final_priority} (#{elapsed}ms)")

          {:ok, []} ->
            IO.puts("  SKIP no classification (#{elapsed}ms)")

          {:error, reason} ->
            IO.puts("  ERROR #{inspect(reason)} (#{elapsed}ms)")
        end
      end

      GenServer.stop(triage_name)
    end
  end
end
