defmodule Kerf.Agents.EmailTriage.Enricher do
  @moduledoc """
  Oban worker that runs the LLM-based enrichment stage for a triaged email.

  Pipeline per spec §4.3:
    1. Load TriageRecord + joined Document
    2. Status guard:
       * "classified"     → proceed
       * "enriched"       → no-op success (idempotent)
       * "unclassifiable" → no-op success (terminal state)
       * "pending"        → {:error, :unexpected_status} (caller bug)
    3. Build adapter input from Document + TriageRecord (truncate body to 2000 bytes)
    4. Call `Kerf.LLM.Enrich.enrich/2` (or test-injected enrich_fn)
    5. Persist enrichment + record taxonomy proposals inside Repo.transaction
    6. Return :ok or {:error, reason} for Oban to handle retry/dead-letter

  Router enqueue is intentionally out of scope here (Step 11). The Enricher's
  contract ends at triage_status = "enriched".
  """

  use Oban.Worker,
    queue: :email_enrichment,
    max_attempts: 3,
    unique: [period: 300, fields: [:args, :worker]]

  require Logger

  alias Kerf.Repo
  alias Kerf.Agents.EmailTriage.{Router, TriageRecord, Taxonomy}
  alias Kerf.KnowledgeBase.Document

  @body_max_bytes 2000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    triage_record_id = args["triage_record_id"]

    case Repo.get(TriageRecord, triage_record_id) do
      nil -> {:error, :not_found}
      record -> handle_record(record)
    end
  end

  # ---------- status guards ----------

  defp handle_record(%TriageRecord{triage_status: "classified"} = record), do: do_enrich(record)
  defp handle_record(%TriageRecord{triage_status: "enriched"}), do: :ok
  defp handle_record(%TriageRecord{triage_status: "unclassifiable"}), do: :ok
  defp handle_record(%TriageRecord{triage_status: "pending"}), do: {:error, :unexpected_status}
  defp handle_record(%TriageRecord{}), do: {:error, :unexpected_status}

  # ---------- main pipeline ----------

  defp do_enrich(record) do
    doc = Repo.get!(Document, record.document_id)
    input = build_input(doc, record)

    accepted_topics = Taxonomy.list_accepted(:topic)
    accepted_actions = Taxonomy.list_accepted(:action)

    enrich = enrich_fn()

    enrich_opts = [
      accepted_topics: accepted_topics,
      accepted_actions: accepted_actions
    ]

    case enrich.(input, enrich_opts) do
      {:ok, result} ->
        case persist(record, result) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # Persist enrichment + record taxonomy proposals atomically. If any
  # proposal call returns an error, the entire transaction (including the
  # TriageRecord update) rolls back. The rollback reason is the full
  # {:proposal_failed, dimension, value, underlying_error} tuple — kept
  # intact as a debugging breadcrumb for prod diagnostics.
  defp persist(record, result) do
    record_proposal = record_proposal_fn()

    Repo.transaction(fn ->
      {:ok, _updated} =
        record
        |> TriageRecord.enrich_changeset(%{
          urgency: result.urgency,
          action: result.action,
          topic: result.topic,
          summary: result.summary
        })
        |> Repo.update()

      Enum.each(result.proposals.topic, fn value ->
        case record_proposal.(:topic, value, record.id) do
          :ok -> :ok
          err -> Repo.rollback({:proposal_failed, :topic, value, err_reason(err)})
        end
      end)

      Enum.each(result.proposals.action, fn value ->
        case record_proposal.(:action, value, record.id) do
          :ok -> :ok
          err -> Repo.rollback({:proposal_failed, :action, value, err_reason(err)})
        end
      end)

      # Step 11: enqueue Router for action evaluation. Inside the transaction
      # so rollback semantics from proposal-recording failures also discard
      # the Router enqueue — no orphan routing for records that didn't reach
      # "enriched" state. unique: false matches the Step 10 EmailTriage call
      # site convention (operator-deliberate inserts bypass the worker-level
      # dedup window).
      %{triage_record_id: record.id}
      |> Router.new(unique: false)
      |> Oban.insert!()
    end)
  end

  # Normalise the underlying error: unwrap {:error, reason} to just reason,
  # leave anything else as-is. Keeps the rollback tuple readable.
  defp err_reason({:error, reason}), do: reason
  defp err_reason(other), do: other

  # ---------- input construction ----------

  defp build_input(doc, record) do
    subject = doc.title || doc.source_metadata["subject"] || ""
    body_text = truncate_body(doc.raw_text)

    %{
      from: %{
        email: doc.source_metadata["sender"],
        name: doc.source_metadata["sender_name"]
      },
      subject: subject,
      body_text: body_text,
      sender_type: record.sender_type,
      source_metadata: doc.source_metadata
    }
  end

  # Truncate raw_text to @body_max_bytes characters. Empty/nil bodies pass
  # through unchanged so the adapter's synthetic-body fallback engages.
  defp truncate_body(nil), do: nil
  defp truncate_body(""), do: ""

  defp truncate_body(text) when is_binary(text) do
    if byte_size(text) <= @body_max_bytes do
      text
    else
      String.slice(text, 0, @body_max_bytes)
    end
  end

  # Adapter is configurable via Application env for test injection.
  # Production never overrides this; default is &Kerf.LLM.Enrich.enrich/2.
  defp enrich_fn do
    Application.get_env(:kerf, __MODULE__, [])[:enrich_fn] || (&Kerf.LLM.Enrich.enrich/2)
  end

  # Taxonomy.record_proposal/3 is configurable via Application env for test
  # injection (e.g. simulating a DB constraint violation mid-transaction).
  # Production never overrides this; default is
  # &Kerf.Agents.EmailTriage.Taxonomy.record_proposal/3.
  defp record_proposal_fn do
    Application.get_env(:kerf, __MODULE__, [])[:record_proposal_fn] ||
      (&Kerf.Agents.EmailTriage.Taxonomy.record_proposal/3)
  end
end
