defmodule Kerf.Eval.Replay do
  @moduledoc """
  Lightning Phase 1 replay harness core
  (docs/superpowers/specs/SPEC_D_lightning_phase1_eval.md).

  Pure/testable functions used by the `mix kerf.eval.replay` task. Kept in a
  plain module, separate from `Mix.Tasks.Kerf.Eval.Replay` itself, so the
  harness core is testable as functions rather than via `Mix.Task.run/1` —
  per SPEC_D §9's deliverable ("tests exercise JSONL parsing, output record
  shape, error tolerance, and the seam call via injected provider_fn — no
  live endpoint in tests").

  Golden-set-v1.jsonl line shape, per the Phase 0 baseline spec §5.3 (outer
  private docs tree, `spec-lightning-swap-phase0-baseline.md` — not in this
  repo, consulted for schema fidelity since SPEC_D itself doesn't specify
  the input JSONL shape):

      {"doc_id": "...", "stratum": "llm_fallback", "label_prod": "...",
       "classifier": "...", "corrected": false,
       "subject": "...", "sender_domain": "...", "body": "...",
       "inserted_at": "..."}

  Note: the golden set carries `sender_domain`, not a full sender address
  (deliberate PII reduction per the Phase 0 spec's §5.3 notes) —
  `parse_golden_line/1` synthesizes a placeholder `email.from.email` from
  it. This is a real fidelity gap against production's actual From header,
  called out in the SPEC_D Stage 2 read-back report rather than silently
  assumed.
  """

  alias Kerf.Agents.EmailTriage.Classifier

  @doc """
  Parse one golden-set JSONL line into the `%{doc_id:, email:}` shape
  `Classifier.classify/2`'s prompt builder needs: `email.from.email`,
  `email.from.name`, `email.subject`, `email.body_text`.

  Returns `{:error, reason}` (never raises) on malformed JSON or a missing
  required field (`doc_id`, `subject`, `body`) — the caller records the
  error and continues past this line.
  """
  @spec parse_golden_line(String.t()) ::
          {:ok, %{doc_id: String.t(), email: map()}} | {:error, String.t()}
  def parse_golden_line(_line), do: raise("not implemented")

  @doc """
  Read a golden-set JSONL file and parse every line via `parse_golden_line/1`.

  Returns `{:ok, results}` where `results` is a list, one entry per input
  line, in file order: `{:ok, %{doc_id:, email:}}` for a valid line,
  `{:error, %{line: pos_integer(), reason: String.t()}}` for a malformed
  one. A malformed line does not stop the read — every other line still
  parses (partial-failure tolerance at the input-parsing layer).
  """
  @spec parse_golden_jsonl(String.t()) ::
          {:ok, [{:ok, map()} | {:error, map()}]} | {:error, term()}
  def parse_golden_jsonl(_path), do: raise("not implemented")

  @doc """
  Build one per-email output JSONL record.

  Fields, per SPEC_D §2 plus the Stage 2 RED authorization (which extends
  §2's explicit field list with `priority_out` — needed for the raw-priority
  comparator SPEC_D §3 item 2 locks in: "C1 raw priority vs A1 raw
  priority"): `doc_id`, `run_tag`, `category_out`, `priority_out`,
  `raw_response`, `schema_valid`, `latency_ms`, `input_tokens`,
  `output_tokens`, `error`.

  Any field omitted from `fields` defaults to `nil` in the returned record
  — callers only supply what they have.
  """
  @spec build_output_record(map()) :: map()
  def build_output_record(_fields), do: raise("not implemented")

  @doc """
  Build the run-manifest header line: `endpoint`, `model`, `temperature`,
  `top_p`, `thinking`, `run_tag`, and `input_sha256` (SHA-256 of the file at
  `opts[:input_path]`, lowercase hex) — the reproducible-in-configuration
  record SPEC_D §2's determinism note requires.
  """
  @spec build_run_manifest(keyword()) :: map()
  def build_run_manifest(_opts), do: raise("not implemented")

  @doc """
  Classify one golden-set email through the real `Classifier.classify/2`
  seam, timing the call and building its output record.

  `provider_fn` is the harness-constructed 4-arity wrapper (explicit
  function, never the bare `&complete/3` capture — CLAUDE.md's
  VLLMProvider nested-default-args gotcha) — injected exactly as
  `Classifier.classify/2` expects: `(schema_name, model, messages, opts) ->
  {:ok, result} | {:error, reason}`.
  """
  @spec classify_email(map(), String.t(), String.t(), function(), String.t()) :: map()
  def classify_email(_email, _doc_id, _run_tag, _provider_fn, _model),
    do: raise("not implemented")

  @doc """
  Classify a batch of already-parsed golden-set records, in order, via
  `classify_email/5`. Partial-failure tolerant: one record's classification
  failure produces an error record for that email only — the batch
  continues through the rest, mirroring
  `Kerf.Agents.EmailTriage.EmailTriage`'s per-document try/rescue/catch
  (`lib/kerf/agents/email_triage/email_triage.ex:61-81`).
  """
  @spec classify_batch([map()], String.t(), function(), String.t()) :: [map()]
  def classify_batch(_records, _run_tag, _provider_fn, _model), do: raise("not implemented")
end
