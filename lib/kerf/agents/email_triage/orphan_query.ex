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

  @doc """
  Return up to `limit` orphaned email-document ids, newest-first.

  Raises until GREEN — present only so the RED suite compiles.
  """
  def orphan_document_ids(_limit) do
    raise "Kerf.Agents.EmailTriage.OrphanQuery.orphan_document_ids/1 not implemented (RED — SPEC C Part 1)"
  end
end
