defmodule Kerf.Agents.EmailTriage.Taxonomy do
  @moduledoc """
  Curated vocabulary for `topic` and `action` label dimensions on `email_triage`.

  Public API per spec §4.7:
    * `list_accepted/1`    — list strings currently in the vocab
    * `list_pending/1`     — list LLM-proposed values awaiting human review
    * `record_proposal/3`  — log a proposal; insert pending row or bump usage_count
    * `accept/2`           — flip pending → accepted
    * `reject/2`           — delete a pending row (DELETE semantics, no rejected_at)
    * `rename/3`           — atomic rename across taxonomy + every TriageRecord

  Dual-table dispatch via `schema_for/1`.
  """

  require Logger
  import Ecto.Query

  alias Kerf.Repo
  alias Kerf.Agents.EmailTriage.{TopicTaxonomy, ActionTaxonomy, TriageRecord}

  @type dimension :: :topic | :action

  # ---------- public API ----------

  @spec list_accepted(dimension()) :: [String.t()]
  def list_accepted(dimension) do
    schema = schema_for(dimension)

    from(t in schema, where: t.accepted == true, select: t.value)
    |> Repo.all()
  end

  @spec list_pending(dimension()) :: [map()]
  def list_pending(dimension) do
    schema = schema_for(dimension)

    from(t in schema,
      where: t.accepted == false,
      select: %{
        value: t.value,
        usage_count: t.usage_count,
        proposed_at: t.proposed_at,
        proposed_by: t.proposed_by
      }
    )
    |> Repo.all()
  end

  @spec record_proposal(dimension(), String.t(), binary()) :: :ok
  def record_proposal(dimension, value, triage_record_id) do
    Logger.info(
      "taxonomy proposal recorded: dimension=#{dimension} value=#{value} triage_record_id=#{triage_record_id}",
      dimension: to_string(dimension),
      value: value,
      triage_record_id: triage_record_id
    )

    schema = schema_for(dimension)

    case Repo.get(schema, value) do
      nil ->
        struct(schema,
          value: value,
          accepted: false,
          proposed_by: "llm",
          proposed_at: DateTime.utc_now(:microsecond),
          usage_count: 1
        )
        |> Repo.insert!()

      %{accepted: true} ->
        # No-op: usage_count is a review-period metric, frozen at acceptance.
        :noop

      %{accepted: false} = pending ->
        pending
        |> Ecto.Changeset.change(usage_count: pending.usage_count + 1)
        |> Repo.update!()
    end

    :ok
  end

  @spec accept(dimension(), String.t()) :: :ok | {:error, :not_found}
  def accept(dimension, value) do
    schema = schema_for(dimension)

    case Repo.get(schema, value) do
      nil ->
        {:error, :not_found}

      %{accepted: true} ->
        :ok

      entry ->
        entry
        |> Ecto.Changeset.change(
          accepted: true,
          accepted_at: DateTime.utc_now(:microsecond)
        )
        |> Repo.update!()

        :ok
    end
  end

  @spec reject(dimension(), String.t()) :: :ok | {:error, :cannot_reject_accepted}
  def reject(dimension, value) do
    schema = schema_for(dimension)

    case Repo.get(schema, value) do
      nil ->
        :ok

      %{accepted: true} ->
        {:error, :cannot_reject_accepted}

      pending ->
        Repo.delete!(pending)
        :ok
    end
  end

  @spec rename(dimension(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :conflict}
  def rename(dimension, from, to) do
    schema = schema_for(dimension)

    case Repo.get(schema, from) do
      nil ->
        {:error, :not_found}

      source ->
        case Repo.get(schema, to) do
          nil -> do_rename(dimension, schema, source, to)
          _ -> {:error, :conflict}
        end
    end
  end

  # ---------- private ----------

  defp schema_for(:topic), do: TopicTaxonomy
  defp schema_for(:action), do: ActionTaxonomy

  defp do_rename(dimension, schema, source, to) do
    Repo.transaction(fn ->
      update_triage_records!(dimension, source.value, to)

      # PK is `value`, so renaming = delete + insert. Both inside the tx.
      Repo.delete!(source)

      struct(schema,
        value: to,
        accepted: source.accepted,
        proposed_by: source.proposed_by,
        proposed_at: source.proposed_at,
        accepted_at: source.accepted_at,
        usage_count: source.usage_count,
        description: source.description
      )
      |> Repo.insert!()
    end)

    :ok
  end

  # Branch on dimension early so the SQL paths don't share code awkwardly.
  defp update_triage_records!(:topic, from, to) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE email_triage SET topic = array_replace(topic, $1, $2) WHERE $1 = ANY(topic)",
      [from, to]
    )
  end

  defp update_triage_records!(:action, from, to) do
    from(t in TriageRecord, where: t.action == ^from)
    |> Repo.update_all(set: [action: to])
  end
end
