defmodule Kerf.Agents.EmailTriage.Reconciler do
  @moduledoc """
  SPEC C Part 2 — orphan reconciler cron enqueuer.

  Thin cron worker: selects `OrphanQuery.orphan_document_ids/1` filtered to
  `inserted_at < now() - grace` (grace so in-flight ingests aren't touched) and
  enqueues one `ReconcileDoc` job per orphaned document id. Singleton — declares
  `unique` on `[:worker]` across pending+running states so overlapping cron ticks
  don't double-enqueue.

  Config: `Application.get_env(:kerf, __MODULE__, [])` — `:limit` (default 20),
  `:grace_seconds` (default 600).
  """

  use Oban.Worker,
    queue: :email_reconcile,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:scheduled, :available, :executing, :retryable]
    ]

  import Ecto.Query

  alias Kerf.Repo
  alias Kerf.KnowledgeBase.Document
  alias Kerf.Agents.EmailTriage.{OrphanQuery, ReconcileDoc}

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:kerf, __MODULE__, [])
    limit = Keyword.get(config, :limit, 20)
    grace_seconds = Keyword.get(config, :grace_seconds, 600)

    cutoff = DateTime.add(DateTime.utc_now(:second), -grace_seconds, :second)

    # Reuse Part 1 for the orphan definition (ids, newest-first, limited), then
    # keep only those aged past the grace window (in-flight ingests untouched).
    ids = OrphanQuery.orphan_document_ids(limit)

    aged_ids =
      from(d in Document, where: d.id in ^ids and d.inserted_at < ^cutoff, select: d.id)
      |> Repo.all()

    Enum.each(aged_ids, fn document_id ->
      %{document_id: document_id}
      |> ReconcileDoc.new()
      |> Oban.insert()
    end)

    :ok
  end
end
