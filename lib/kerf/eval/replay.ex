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

  @output_fields ~w(
    doc_id run_tag category_out priority_out raw_response schema_valid
    latency_ms input_tokens output_tokens error
  )a

  @raw_response_key :kerf_eval_raw_response

  @doc """
  Parse one golden-set JSONL line into the `%{doc_id:, email:}` shape
  `Classifier.classify/2`'s prompt builder needs: `email.from.email`,
  `email.from.name`, `email.subject`, `email.body_text`.

  Returns `{:error, reason}` (never raises) on malformed JSON or a missing
  `doc_id` — the caller records the error and continues past this line.
  `doc_id` is the only required field.

  `subject` and `body` both coalesce a missing or `nil` value to `""`,
  mirroring production exactly rather than treating either as a parse
  error: `email_triage.ex:132`/`:137` read `subject: doc.title || ""` and
  `:138` reads `body_text: doc.raw_text || ""`. This is not a rare edge
  case — 37% of production documents (11,798/32,168) have `NULL raw_text`,
  and 57 of the 241 golden rows do too (SPEC_D Stage 2d).

  `email.from.email` is synthesized as `"unknown@" <> sender_domain` — the
  golden set carries only `sender_domain`, not a full address (PII
  reduction, Phase 0 baseline spec §5.3). `email.from.name` is always
  `nil`. Pinned per SPEC_D Stage 2 read-back disposition (flag 1).
  """
  @spec parse_golden_line(String.t()) ::
          {:ok, %{doc_id: String.t(), email: map()}} | {:error, String.t()}
  def parse_golden_line(line) do
    case Jason.decode(line) do
      {:ok, data} when is_map(data) ->
        with {:ok, doc_id} <- fetch_required(data, "doc_id") do
          email = %{
            from: %{email: "unknown@#{Map.get(data, "sender_domain")}", name: nil},
            subject: coalesce(Map.get(data, "subject")),
            body_text: coalesce(Map.get(data, "body"))
          }

          {:ok, %{doc_id: doc_id, email: email}}
        end

      {:ok, _non_map} ->
        {:error, "golden-set line must be a JSON object"}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "invalid JSON: #{Exception.message(err)}"}
    end
  end

  defp fetch_required(data, key) do
    case Map.get(data, key) do
      nil -> {:error, "missing required field: #{key}"}
      "" -> {:error, "missing required field: #{key}"}
      value -> {:ok, value}
    end
  end

  defp coalesce(nil), do: ""
  defp coalesce(value), do: value

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
  def parse_golden_jsonl(path) do
    case File.read(path) do
      {:ok, content} ->
        results =
          content
          |> String.split("\n", trim: true)
          |> Enum.with_index(1)
          |> Enum.map(fn {line, line_no} ->
            case parse_golden_line(line) do
              {:ok, record} -> {:ok, record}
              {:error, reason} -> {:error, %{line: line_no, reason: reason}}
            end
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
  def build_output_record(fields) do
    Map.new(@output_fields, fn key -> {key, Map.get(fields, key)} end)
  end

  @doc """
  Build the run-manifest header line: `endpoint`, `model`, `temperature`,
  `top_p`, `thinking`, `run_tag`, and `input_sha256` (SHA-256 of the file at
  `opts[:input_path]`, lowercase hex) — the reproducible-in-configuration
  record SPEC_D §2's determinism note requires.
  """
  @spec build_run_manifest(keyword()) :: map()
  def build_run_manifest(opts) do
    input_path = Keyword.fetch!(opts, :input_path)
    input_sha256 = input_path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    %{
      type: "manifest",
      run_tag: Keyword.get(opts, :run_tag),
      endpoint: Keyword.get(opts, :endpoint),
      model: Keyword.get(opts, :model),
      temperature: Keyword.get(opts, :temperature),
      top_p: Keyword.get(opts, :top_p),
      thinking: Keyword.get(opts, :thinking),
      input_sha256: input_sha256
    }
  end

  @required_args ~w(input output endpoint model tag)a

  @doc """
  Parse `mix kerf.eval.replay` argv into a config map, per SPEC_D §2's CLI
  contract: `--input --output --endpoint --model --tag [--thinking on|off]
  [--temperature T --top-p P] [--limit N]`.

  Required: `:input, :output, :endpoint, :model, :tag` (strings) — missing
  any one returns `{:error, reason}` naming the flag, never raises.
  Optional, default `nil` when absent: `:thinking` (`:on | :off`),
  `:temperature`/`:top_p` (float), `:limit` (integer). A `nil` `:thinking`
  means "not specified" — distinct from `:off` — so the harness's
  provider_fn can tell "send no chat_template_kwargs at all" (Cascade, or
  an unspecified Lightning run) apart from an explicit `--thinking off`.
  """
  @spec parse_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          input: :string,
          output: :string,
          endpoint: :string,
          model: :string,
          tag: :string,
          thinking: :string,
          temperature: :string,
          top_p: :string,
          limit: :string
        ]
      )

    opts_map = Map.new(opts)

    case Enum.find(@required_args, fn key -> !Map.has_key?(opts_map, key) end) do
      nil ->
        {:ok,
         %{
           input: opts_map.input,
           output: opts_map.output,
           endpoint: opts_map.endpoint,
           model: opts_map.model,
           tag: opts_map.tag,
           thinking: parse_thinking(Map.get(opts_map, :thinking)),
           temperature: parse_float(Map.get(opts_map, :temperature)),
           top_p: parse_float(Map.get(opts_map, :top_p)),
           limit: parse_integer(Map.get(opts_map, :limit))
         }}

      missing_key ->
        {:error, "missing required flag: --#{dasherize(missing_key)}"}
    end
  end

  defp dasherize(:top_p), do: "top-p"
  defp dasherize(key), do: Atom.to_string(key)

  defp parse_thinking(nil), do: nil
  defp parse_thinking("on"), do: :on
  defp parse_thinking("off"), do: :off

  defp parse_float(nil), do: nil
  defp parse_float(str), do: String.to_float(str)

  defp parse_integer(nil), do: nil
  defp parse_integer(str), do: String.to_integer(str)

  @doc """
  Stash `{raw_content, usage}` for the in-flight `classify_email/5` call to
  read back after `Classifier.classify/2` returns.

  Called by the harness's innermost 3-arity provider wrapper (the one
  passed to `StructuredOutput.complete_with_schema/4`'s `:provider_fn`) —
  the only place in the pipeline that still has the pre-parse LLM response;
  `Classifier.classify/2`'s own return value discards both the raw text and
  token usage. Safe only under this harness's locked sequential,
  one-email-at-a-time execution (SPEC_D Stage 2 authorization) — a process
  dictionary is not a safe side-channel under concurrency.
  """
  @spec stash_raw_response(String.t() | nil, map() | nil) :: :ok
  def stash_raw_response(raw_content, usage) do
    Process.put(@raw_response_key, {raw_content, usage})
    :ok
  end

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
  def classify_email(email, doc_id, run_tag, provider_fn, model) do
    Process.delete(@raw_response_key)
    started_at = System.monotonic_time(:millisecond)
    result = Classifier.classify(email, provider_fn: provider_fn, model: model)
    latency_ms = System.monotonic_time(:millisecond) - started_at
    {raw_content, usage} = Process.get(@raw_response_key, {nil, nil})
    Process.delete(@raw_response_key)

    case result do
      {:ok, classification} ->
        build_output_record(%{
          doc_id: doc_id,
          run_tag: run_tag,
          category_out: classification.category,
          priority_out: classification.priority,
          raw_response: raw_content || classification,
          schema_valid: true,
          latency_ms: latency_ms,
          input_tokens: usage && usage[:input_tokens],
          output_tokens: usage && usage[:output_tokens],
          error: nil
        })

      {:error, reason} ->
        build_output_record(%{
          doc_id: doc_id,
          run_tag: run_tag,
          raw_response: raw_content,
          schema_valid: false,
          latency_ms: latency_ms,
          input_tokens: usage && usage[:input_tokens],
          output_tokens: usage && usage[:output_tokens],
          error: inspect(reason)
        })
    end
  end

  @doc """
  Classify a batch of already-parsed golden-set records, in order, via
  `classify_email/5`. Partial-failure tolerant: one record's classification
  failure — or a raise from a misbehaving `provider_fn` — produces an error
  record for that email only — the batch continues through the rest,
  mirroring `Kerf.Agents.EmailTriage.EmailTriage`'s per-document
  try/rescue/catch (`lib/kerf/agents/email_triage/email_triage.ex:61-81`).
  """
  @spec classify_batch([map()], String.t(), function(), String.t()) :: [map()]
  def classify_batch(records, run_tag, provider_fn, model) do
    Enum.map(records, fn %{doc_id: doc_id, email: email} ->
      try do
        classify_email(email, doc_id, run_tag, provider_fn, model)
      rescue
        e ->
          build_output_record(%{
            doc_id: doc_id,
            run_tag: run_tag,
            schema_valid: false,
            error: Exception.message(e)
          })
      catch
        kind, value ->
          build_output_record(%{
            doc_id: doc_id,
            run_tag: run_tag,
            schema_valid: false,
            error: "#{kind}: #{inspect(value)}"
          })
      end
    end)
  end
end
