defmodule Kerf.Eval.Manifest.Item do
  @moduledoc """
  SPEC_H F08.2–F08.5, F08.7 — one item of the Decide labelled set.

  Shape per plan §2.1 (docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md).
  A real item carries `doc_id` (kb_documents.id); a synthetic contrastive b-item
  has `doc_id: nil` and `synthetic_of` set (A3.9). `state` holds PII and only
  ever exists in the private tree. `labels` keys are the `QuestionSet.order/0`
  names; only the category label carries a source (F08.7).

  `source_id` is the kb_documents.source_id beside `doc_id` (nil on synthetic
  items). `seed_category` carries the golden-override category from the export
  (S-29) until labelling fills the full `labels` map.
  """

  @enforce_keys [:id]
  defstruct id: nil,
            doc_id: nil,
            source_id: nil,
            seed_category: nil,
            synthetic_of: nil,
            language: "und",
            language_source: "heuristic",
            state: nil,
            labels: nil,
            label_sources: %{},
            labelled_at: nil,
            labelled_by: nil,
            tier: nil,
            tier_reason: nil,
            tiered_at: nil,
            split: nil,
            pair_id: nil,
            pair_fact: nil

  @type state :: %{
          from: String.t(),
          from_name: String.t() | nil,
          subject: String.t(),
          date: String.t(),
          body: String.t()
        }

  @type labels :: %{String.t() => String.t() | boolean() | 1..5}

  @type t :: %__MODULE__{
          id: String.t(),
          doc_id: String.t() | nil,
          source_id: String.t() | nil,
          seed_category: String.t() | nil,
          synthetic_of: String.t() | nil,
          language: String.t(),
          language_source: String.t(),
          state: state() | nil,
          labels: labels() | nil,
          label_sources: %{String.t() => String.t()},
          labelled_at: String.t() | nil,
          labelled_by: String.t() | nil,
          tier: String.t() | nil,
          tier_reason: String.t() | nil,
          tiered_at: String.t() | nil,
          split: String.t() | nil,
          pair_id: String.t() | nil,
          pair_fact: String.t() | nil
        }
end
