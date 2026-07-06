defmodule Kerf.Agents.EmailTriage.ReconcileDoc do
  @moduledoc """
  SPEC C Part 2 — per-document reconcile worker.

  Runs the real triage path for one orphaned document and maps the outcome to an
  Oban result:

    * triage yields a record (success)   → `:ok` (email_triage row now exists;
      the triage path enqueues the Enricher downstream).
    * triage returns `{:ok, []}` (SKIP)  → `{:error, _}` so Oban retries; on
      exhaustion Oban discards → parked and visible. MUST NOT look like success.
    * triage returns `{:error, reason}`  → `{:error, reason}` (same).

  Declares `unique` on the `document_id` arg **including the `:discarded` state**
  (period `:infinity`) so a doc that exhausted retries is not re-enqueued by a
  later cron tick. `max_attempts: 3`.

  Triage seam: `Application.get_env(:kerf, __MODULE__, [])[:triage_fn]` (a
  `fn document_id -> {:ok, list} | {:error, term} end`), default the real
  `EmailTriage.triage(EmailTriage, [id])` path. Injected in tests so they never
  hit the classifier backend.

  RED skeleton — perform/1 raises until GREEN.
  """

  use Oban.Worker, queue: :email_reconcile, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    raise "Kerf.Agents.EmailTriage.ReconcileDoc.perform/1 not implemented (RED — SPEC C Part 2)"
  end
end
