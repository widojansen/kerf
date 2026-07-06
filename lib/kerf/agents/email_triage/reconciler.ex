defmodule Kerf.Agents.EmailTriage.Reconciler do
  @moduledoc """
  SPEC C Part 2 — orphan reconciler cron enqueuer.

  Thin cron worker: selects `OrphanQuery.orphan_document_ids/1` filtered to
  `inserted_at < now() - grace` (grace so in-flight ingests aren't touched) and
  enqueues one `ReconcileDoc` job per orphaned document id. Singleton — declares
  `unique` on `[:worker]` so overlapping cron ticks don't double-enqueue.

  Config: `Application.get_env(:kerf, __MODULE__, [])` — `:limit` (default 20),
  `:grace_seconds` (default 600).

  RED skeleton — perform/1 raises until GREEN.
  """

  use Oban.Worker, queue: :email_reconcile, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    raise "Kerf.Agents.EmailTriage.Reconciler.perform/1 not implemented (RED — SPEC C Part 2)"
  end
end
