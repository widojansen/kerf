defmodule Kerf.Agents.EmailTriage.TriageRecord do
  @moduledoc """
  Per-email triage record. One row per `kb_documents` row with `source_type = "email"`.

  State machine on `triage_status`:
      pending -> classified -> enriched
              \\-> unclassifiable (terminal)

  Three changesets, one per transition. Each changeset owns its own status
  transition and timestamp — callers supply classification/enrichment data,
  not bookkeeping fields:

    * `classify_changeset/2`        — sets triage_status = "classified",  classified_at = now
    * `enrich_changeset/2`          — sets triage_status = "enriched",    enriched_at   = now
    * `mark_unclassifiable_changeset/2` — sets triage_status = "unclassifiable"

  No schema-level default for `triage_status` or `topic` — the DB column
  defaults ("pending" and `[]`) act as the at-rest safety net. A fresh
  `%TriageRecord{}` struct has both as nil.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Changeset pipeline order: cast → validate_required → put_change → validate_inclusion → constraint checks.
  # Do not reorder; put_change must run after cast (so caller's contradicting value is overwritten,
  # not appended) and before validate_inclusion (so validation sees the final value).

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending classified enriched unclassifiable)

  schema "email_triage" do
    belongs_to :document, Kerf.KnowledgeBase.Document, type: :binary_id

    field :category, :string
    field :sender_type, :string
    field :classifier_source, :string
    field :confidence, :float

    field :urgency, :string
    field :action, :string
    field :topic, {:array, :string}
    field :summary, :string

    field :triage_status, :string
    field :triage_error, :string
    field :enriched_at, :utc_datetime_usec
    field :classified_at, :utc_datetime_usec
    field :enrichment_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  # triage_status is set by the changeset itself, not the caller — omitted from cast.
  @classify_fields ~w(document_id category sender_type classifier_source confidence)a
  @classify_required ~w(document_id category sender_type classifier_source)a

  def classify_changeset(record, attrs) do
    record
    |> cast(attrs, @classify_fields)
    |> validate_required(@classify_required)
    |> put_change(:triage_status, "classified")
    |> put_change(:classified_at, DateTime.utc_now(:microsecond))
    |> validate_inclusion(:triage_status, @valid_statuses)
    |> foreign_key_constraint(:document_id)
    |> unique_constraint(:document_id)
  end

  @enrich_fields ~w(urgency action topic summary enrichment_version)a
  @enrich_required ~w(urgency action summary)a

  def enrich_changeset(record, attrs) do
    record
    |> cast(attrs, @enrich_fields)
    |> validate_required(@enrich_required)
    |> validate_length(:topic, min: 1, max: 4)
    |> put_change(:triage_status, "enriched")
    |> put_change(:enriched_at, DateTime.utc_now(:microsecond))
    |> validate_inclusion(:triage_status, @valid_statuses)
  end

  @unclassifiable_fields ~w(triage_error)a
  @unclassifiable_required ~w(triage_error)a

  def mark_unclassifiable_changeset(record, attrs) do
    record
    |> cast(attrs, @unclassifiable_fields)
    |> validate_required(@unclassifiable_required)
    |> put_change(:triage_status, "unclassifiable")
    |> validate_inclusion(:triage_status, @valid_statuses)
  end
end
