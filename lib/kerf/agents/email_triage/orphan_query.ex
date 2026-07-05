defmodule Kerf.Agents.EmailTriage.OrphanQuery do
  @moduledoc """
  Shared "orphaned email document" query (SPEC C, Part 1).

  An orphan is a `kb_documents` row with `source_type = "email"` that has **no**
  `email_triage` row — the authoritative definition used by BOTH the corrected
  `mix kerf.backfill_triage` selection and the reconciler (Part 2).

  This replaces the earlier, buggy "no `kb_feedback` triage row" selection: the
  23 classification-error orphans DO carry a `kb_feedback` breadcrumb, so the old
  anti-join skipped exactly the rows that most needed recovery. The correct
  anti-join is on `email_triage.document_id`, not `kb_feedback`.
  """

  import Ecto.Query

  alias Kerf.Repo
  alias Kerf.KnowledgeBase.Document
  alias Kerf.Agents.EmailTriage.TriageRecord

  @doc """
  Return up to `limit` orphaned email-document ids, newest-first.

  Anti-join: email `kb_documents` LEFT JOIN `email_triage` on `document_id`,
  keeping rows where the triage side `IS NULL`. Ordered `inserted_at DESC` with
  an `id DESC` tiebreaker so ties (same-timestamp rows) are stable under `limit`.
  """
  def orphan_document_ids(limit) do
    from(d in Document,
      left_join: t in TriageRecord,
      on: t.document_id == d.id,
      where: d.source_type == "email" and is_nil(t.id),
      order_by: [desc: d.inserted_at, desc: d.id],
      limit: ^limit,
      select: d.id
    )
    |> Repo.all()
  end
end
