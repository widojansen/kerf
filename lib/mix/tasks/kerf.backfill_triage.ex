defmodule Mix.Tasks.Kerf.BackfillTriage do
  @shortdoc "Triage emails in the KB that have no feedback records"
  @moduledoc """
  Runs the email triage pipeline on emails that were ingested but never triaged.
  Starts its own EmailTriage GenServer — does not require the release to be running.

  ## Usage

      # Preview what would be triaged
      MIX_ENV=prod mix kerf.backfill_triage --dry-run -n 20

      # Triage 10 emails (start small)
      MIX_ENV=prod mix kerf.backfill_triage -n 10

      # Triage all untriaged
      MIX_ENV=prod mix kerf.backfill_triage -n 1000
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

    alias Kerf.KnowledgeBase.Document
    alias Kerf.Agents.EmailTriage.{EmailTriage, OrphanQuery}

    # Orphans = email docs with NO email_triage row (anti-join on
    # email_triage.document_id). Replaces the old "no kb_feedback triage row"
    # selection, which skipped the classification-error orphans (they DO carry a
    # kb_feedback breadcrumb but no triage row) — the exact rows recovery needs.
    orphan_ids = OrphanQuery.orphan_document_ids(limit)

    untriaged =
      from(d in Document,
        where: d.id in ^orphan_ids,
        order_by: [desc: d.inserted_at, desc: d.id]
      )
      |> Kerf.Repo.all()

    IO.puts("Found #{length(untriaged)} orphaned email doc(s) with no email_triage row (limit #{limit})")

    if dry_run do
      for doc <- untriaged do
        from = doc.source_metadata["sender"] || "unknown"
        subject = doc.title || "no subject"
        IO.puts("  #{from} -- #{subject}")
      end
    else
      # Start a local EmailTriage GenServer for this backfill run
      triage_name = :"backfill_triage_#{System.unique_integer([:positive])}"

      triage_config = Application.get_env(:kerf, Kerf.Agents.EmailTriage, [])

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
