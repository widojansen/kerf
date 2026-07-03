defmodule Kerf.Agents.EmailTriage.DigestWorker do
  @moduledoc """
  Cron-triggered Oban worker that drains undigested `:telegram_digest` routing
  decisions into a single Telegram message per cron tick (Step 13).

  Pipeline (inside `Repo.transaction`):
    1. Query `email_routing_decisions WHERE digested_at IS NULL AND action_taken = "telegram_digest"`
       ordered by `inserted_at`
    2. Empty list → insert `DigestRun{status: "empty"}`, return `:ok`
    3. Non-empty:
       a. Compute `window_start` (min inserted_at) and `window_end` (now)
       b. Project to display items (`%{name, category}`)
       c. Compute `since_label` from the most recent `DigestRun.sent_at`
       d. Format via `TelegramFormatter.format_routing_digest/2`
       e. Send via configured telegram_sender
       f. On send `:ok`: `UPDATE digested_at` on the drained rows + insert `DigestRun{status: "sent"}`
       g. On send `{:error, _}`: `Repo.rollback({:send_failed, reason})` — full rollback,
          rows stay undigested, worker returns `{:error, _}`, Oban retries.

  Job args are ignored (cron tick passes empty args).
  """

  use Oban.Worker, queue: :email_digest, max_attempts: 3

  import Ecto.Query

  alias Kerf.Repo
  alias Kerf.Agents.EmailTriage.{DigestRun, RoutingDecision, TelegramFormatter, TriageRecord}
  alias Kerf.KnowledgeBase.{Document, EmailSender}

  @impl Oban.Worker
  def perform(_job) do
    result =
      Repo.transaction(fn ->
        decisions = list_undigested()

        case decisions do
          [] ->
            insert_empty_run!()
            :ok

          rows ->
            window_start = compute_window_start(rows)
            sent_at = DateTime.utc_now(:microsecond)
            items = project_items(rows)
            since_label = compute_since_label(sent_at)

            text = TelegramFormatter.format_routing_digest(items, since_label: since_label)

            case telegram_sender().(resolve_chat_id(), text) do
              :ok ->
                ids = Enum.map(rows, & &1.id)
                mark_digested!(ids, sent_at)
                insert_sent_run!(length(rows), window_start, sent_at)
                :ok

              {:error, reason} ->
                Repo.rollback({:send_failed, reason})
            end
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------- queries ----------

  defp list_undigested do
    from(d in RoutingDecision,
      where: is_nil(d.digested_at) and d.action_taken == "telegram_digest",
      order_by: [asc: d.inserted_at]
    )
    |> Repo.all()
  end

  defp compute_window_start(rows) do
    rows |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)
  end

  defp project_items(rows) do
    # Bulk-load triage + document in two queries (was N+1 per row — SPEC B gate).
    triage_ids = Enum.map(rows, & &1.email_triage_id)

    triages =
      from(t in TriageRecord, where: t.id in ^triage_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    doc_ids = triages |> Map.values() |> Enum.map(& &1.document_id)

    docs =
      from(d in Document, where: d.id in ^doc_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn dec ->
      triage = Map.fetch!(triages, dec.email_triage_id)
      doc = Map.fetch!(docs, triage.document_id)
      project_row(dec, triage, doc)
    end)
  end

  @doc """
  Project a single `%RoutingDecision{}` to a digest item (SPEC B).

  For `category == "transactional"` the item carries per-email fields for inline
  itemisation — `%{category: "transactional", sender:, subject:, timestamp:}`
  (sender name-preferred, subject → `title` fallback, timestamp =
  `decision.inserted_at`). Every other category keeps the count-only
  `%{name:, category:}` shape.
  """
  def project_item(%RoutingDecision{} = decision) do
    triage = Repo.get!(TriageRecord, decision.email_triage_id)
    doc = Repo.get!(Document, triage.document_id)
    project_row(decision, triage, doc)
  end

  defp project_row(decision, triage, doc) do
    case triage.category do
      "transactional" -> transactional_item(decision, doc)
      _ -> count_item(triage, doc)
    end
  end

  # Transactional: per-email record for inline itemisation. Sender/subject come
  # straight from source_metadata (no email_senders lookup); timestamp is the
  # decision's insert time (UTC), converted to display tz by the renderer.
  defp transactional_item(decision, doc) do
    meta = doc.source_metadata || %{}

    %{
      category: "transactional",
      sender: meta["sender_name"] || meta["sender"] || "(unknown)",
      subject: meta["subject"] || doc.title || "(no subject)",
      timestamp: decision.inserted_at
    }
  end

  # Non-transactional: unchanged count-only projection (name via email_senders).
  defp count_item(triage, doc) do
    sender_email = (doc.source_metadata || %{})["sender"] || ""

    name =
      case sender_email do
        "" ->
          (doc.source_metadata || %{})["sender_name"] || "(unknown)"

        email ->
          case Repo.get_by(EmailSender, email: email) do
            nil -> (doc.source_metadata || %{})["sender_name"] || email
            %{name: nil} -> (doc.source_metadata || %{})["sender_name"] || email
            sender -> sender.name
          end
      end

    %{name: name, category: triage.category || "uncategorized"}
  end

  defp compute_since_label(now) do
    case last_sent_at() do
      nil ->
        "today"

      last ->
        diff_seconds = DateTime.diff(now, last, :second)
        hours = div(diff_seconds, 3600)

        cond do
          hours < 1 -> "<1h"
          hours == 1 -> "1h"
          true -> "#{hours}h"
        end
    end
  end

  defp last_sent_at do
    from(r in DigestRun,
      where: r.status == "sent",
      order_by: [desc: r.sent_at],
      limit: 1,
      select: r.sent_at
    )
    |> Repo.one()
  end

  # ---------- writes ----------

  defp mark_digested!(ids, digested_at) do
    from(d in RoutingDecision, where: d.id in ^ids)
    |> Repo.update_all(set: [digested_at: digested_at])
  end

  defp insert_empty_run! do
    sent_at = DateTime.utc_now(:microsecond)

    %DigestRun{}
    |> DigestRun.changeset(%{
      sent_at: sent_at,
      decision_count: 0,
      status: "empty"
    })
    |> Repo.insert!()
  end

  defp insert_sent_run!(count, window_start, sent_at) do
    %DigestRun{}
    |> DigestRun.changeset(%{
      sent_at: sent_at,
      decision_count: count,
      status: "sent",
      window_start: window_start,
      window_end: sent_at
    })
    |> Repo.insert!()
  end

  # ---------- injection seams ----------

  # Test seam: tests inject a 2-arity fn via Application config.
  # Default wraps Kerf.Channels.Telegram.send_message/3 to (chat_id, text).
  defp telegram_sender do
    Application.get_env(:kerf, __MODULE__, [])[:telegram_sender] ||
      (&Kerf.Channels.Telegram.send_message(&1, &2))
  end

  # Reuses TELEGRAM_ALERT_CHAT_ID (same convention as Router/Step 12).
  defp resolve_chat_id do
    Application.get_env(:kerf, Kerf.Monitor.Alerting, [])[:telegram_chat_id]
  end
end
