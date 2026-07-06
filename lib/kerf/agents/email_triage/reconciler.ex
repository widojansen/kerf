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
  require Logger

  alias Kerf.Repo
  alias Kerf.KnowledgeBase.Document
  alias Kerf.Agents.EmailTriage.{OrphanQuery, ReconcileDoc}

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:kerf, __MODULE__, [])
    limit = Keyword.get(config, :limit, 20)
    grace_seconds = Keyword.get(config, :grace_seconds, 600)
    insert_fn = Keyword.get(config, :insert_fn, &Oban.insert/1)

    cutoff = DateTime.add(DateTime.utc_now(:second), -grace_seconds, :second)

    # Reuse Part 1 for the orphan definition (ids, newest-first, limited), then
    # keep only those aged past the grace window (in-flight ingests untouched).
    ids = OrphanQuery.orphan_document_ids(limit)

    aged_ids =
      from(d in Document, where: d.id in ^ids and d.inserted_at < ^cutoff, select: d.id)
      |> Repo.all()

    Enum.each(aged_ids, &enqueue_reconcile(&1, insert_fn))

    :ok
  end

  # Enqueue one ReconcileDoc and make the outcome visible — never swallow a
  # failed insert (the silent-drop class this spec exists to kill). A unique
  # conflict is expected idempotency (already queued/parked), not a failure.
  defp enqueue_reconcile(document_id, insert_fn) do
    outcome =
      case %{document_id: document_id} |> ReconcileDoc.new() |> insert_fn.() do
        {:ok, %Oban.Job{conflict?: true}} ->
          :conflict

        {:ok, %Oban.Job{}} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Reconciler] failed to enqueue ReconcileDoc for orphan #{document_id}: #{inspect(reason)}"
          )

          :error
      end

    # Per-doc reconcile metric so recurrence is visible, not silent (SPEC C §2).
    :telemetry.execute(
      [:kerf, :reconciler, :enqueue],
      %{count: 1},
      %{document_id: document_id, outcome: outcome}
    )

    outcome
  end
end
