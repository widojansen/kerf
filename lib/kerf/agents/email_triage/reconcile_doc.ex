defmodule Kerf.Agents.EmailTriage.ReconcileDoc do
  @moduledoc """
  SPEC C Part 2 — per-document reconcile worker.

  Runs the real triage path for one orphaned document and maps the outcome to an
  Oban result:

    * triage yields a record (`{:ok, [_ | _]}`) → `:ok` (email_triage row now
      exists; the triage path enqueues the Enricher downstream).
    * triage returns `{:ok, []}` (SKIP) → `{:error, :skip_no_classification}` so
      Oban retries; on exhaustion Oban discards → parked and visible. This is the
      load-bearing failure mode (the triage GenServer never returns `{:error, _}`).
    * triage returns `{:error, reason}` → `{:error, reason}`.

  Declares `unique` on the `document_id` arg **including the `:discarded` state**
  (period `:infinity`) so a doc that exhausted retries is not re-enqueued by a
  later cron tick. `max_attempts: 3`.

  Triage seam: `Application.get_env(:kerf, __MODULE__, [])[:triage_fn]` (a
  `fn document_id -> {:ok, list} | {:error, term} end`), default the real
  `EmailTriage.triage(EmailTriage, [id])` path.
  """

  use Oban.Worker,
    queue: :email_reconcile,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:document_id],
      states: [:scheduled, :available, :executing, :retryable, :discarded]
    ]

  alias Kerf.Agents.EmailTriage.EmailTriage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) do
    triage_fn =
      Application.get_env(:kerf, __MODULE__, [])
      |> Keyword.get(:triage_fn, &default_triage/1)

    case triage_fn.(document_id) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :skip_no_classification}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_triage(document_id) do
    EmailTriage.triage(EmailTriage, [document_id])
  end
end
