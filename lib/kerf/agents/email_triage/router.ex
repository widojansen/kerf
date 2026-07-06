defmodule Kerf.Agents.EmailTriage.Router do
  @moduledoc """
  Oban worker that evaluates routing rules against an enriched `TriageRecord`
  and inserts a `RoutingDecision` audit row.

  Pipeline per spec §4.5:
    1. Load `TriageRecord` by id
    2. If not in `triage_status = "enriched"`, no-op success (Router only runs
       on enriched rows; classified/pending/unclassifiable produce no decision)
    3. Read `RoutingConfig.current/1` ONCE at the top — snapshot pinned for the
       full job. Mid-job reloads affect only subsequent jobs.
    4. Walk rules in order; first match wins
    5. On no-match — the active config's catch-all is `default_digest` (match
       `%{}`), so this only happens if that rule is removed — log a warning and
       record `rule_name: "no_match_fallback", action_taken: :silent`: the live
       fallback for unmatched records is silent — fail safe, not crash
    6. Insert a `RoutingDecision` row with the active config version

  Telegram delivery is out of scope here; Step 12 wires that. The Router's
  contract ends at "decision row inserted."
  """

  use Oban.Worker, queue: :email_routing, max_attempts: 5

  require Logger

  alias Kerf.Repo
  alias Kerf.Agents.EmailTriage.{
    NotifyGuard,
    RoutingConfig,
    RoutingDecision,
    TelegramFormatter,
    TriageRecord
  }
  alias Kerf.KnowledgeBase.{Document, EmailSender}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    triage_record_id = args["triage_record_id"]

    case Repo.get(TriageRecord, triage_record_id) do
      nil -> {:error, :not_found}
      record -> handle_record(record)
    end
  end

  defp handle_record(%TriageRecord{triage_status: "enriched"} = record) do
    config = current_config()
    # Single Document load, shared by the guard (labels/date) and the
    # :telegram_ping delivery (ping formatting) — no double get!.
    doc = Repo.get!(Document, record.document_id)
    {rule_name, action_atom} = pick_rule(record, config.rules)
    action_atom = apply_notify_guard(action_atom, record, doc)
    insert_decision!(record.id, rule_name, action_atom, config.version)
    deliver(action_atom, record, doc)
  end

  # SPEC C Router addendum — universal notify guard at the emission seam.
  # Silences self-sent ("SENT" label) and stale (older than NotifyGuard's
  # MAX_AGE) mail by overriding the routed action to :silent BEFORE the decision
  # row is written — so both the immediate deliver and the DigestWorker cron
  # (WHERE action_taken="telegram_digest") stay silent. The guard is monotonic:
  # it only silences, never un-silences, and the matched rule_name is preserved.
  #
  # A rule that already routes to :silent needs no guard evaluation.
  defp apply_notify_guard(:silent, _record, _doc), do: :silent

  defp apply_notify_guard(action_atom, record, doc) do
    guard_input = guard_input(doc)

    if NotifyGuard.notify?(guard_input, current_time()) do
      action_atom
    else
      Logger.info(
        "[Router] NotifyGuard silenced #{silence_reason(guard_input)} email for " <>
          "triage_record #{record.id} (rule action was #{action_atom})"
      )

      :silent
    end
  end

  # Project the Document's stored Gmail metadata into the guard's input shape.
  defp guard_input(doc) do
    metadata = doc.source_metadata || %{}
    %{labels: metadata["labels"] || [], date: metadata["date"]}
  end

  # Reason label for the silence log. Mirrors NotifyGuard's rule order (rule 1
  # SENT wins over staleness) for operator soak visibility, WITHOUT re-deriving
  # the boolean — notify?/2 stays the single source of truth for the decision.
  defp silence_reason(%{labels: labels}) when is_list(labels) do
    if "SENT" in labels, do: "self-sent", else: "stale"
  end

  defp silence_reason(_), do: "stale"

  # Injectable clock — deterministic in tests via the now_fn seam.
  defp current_time do
    now_fn = Application.get_env(:kerf, __MODULE__, [])[:now_fn] || (&DateTime.utc_now/0)
    now_fn.()
  end

  # Classified / pending / unclassifiable: not yet enriched, no decision.
  defp handle_record(%TriageRecord{}), do: :ok

  # ---------- rule matching ----------

  @doc """
  Returns true if every key in `match_spec` matches the corresponding field in
  `record`. Empty `%{}` always matches (catch-all) — falls out naturally from
  `Enum.all?` on an empty enumerable.
  """
  def matches?(record, match_spec) when is_map(record) and is_map(match_spec) do
    Enum.all?(match_spec, fn {key, expected} ->
      match_field(Map.get(record, key), expected)
    end)
  end

  # Two-clause matcher. New matchers (e.g. {:in, [...]}, regex) add new clauses.
  defp match_field(field_value, {:contains, item}) when is_list(field_value),
    do: item in field_value

  defp match_field(_field_value, {:contains, _}), do: false

  defp match_field(field_value, expected), do: field_value == expected

  # ---------- rule walk ----------

  defp pick_rule(record, rules) do
    record_map = record_to_map(record)

    case Enum.find(rules, fn rule -> matches?(record_map, rule.match) end) do
      nil ->
        Logger.warning(
          "[Router] no matching rule for triage_record #{record.id}; using no_match_fallback (silent)"
        )

        {"no_match_fallback", :silent}

      rule ->
        {rule.name, rule.action}
    end
  end

  # Project the TriageRecord struct into the atom-keyed map shape that match
  # specs target. Only the fields used in routing rules are exposed.
  defp record_to_map(%TriageRecord{} = record) do
    %{
      category: record.category,
      sender_type: record.sender_type,
      urgency: record.urgency,
      action: record.action,
      topic: record.topic || []
    }
  end

  # ---------- decision insert ----------

  # Single point of atom→string conversion — keeps the matcher pure-atom and
  # the storage layer pure-string.
  defp insert_decision!(triage_id, rule_name, action_atom, version) do
    %RoutingDecision{}
    |> RoutingDecision.changeset(%{
      email_triage_id: triage_id,
      rule_name: rule_name,
      action_taken: Atom.to_string(action_atom),
      routing_config_version: version
    })
    |> Repo.insert!()
  end

  # ---------- delivery (Step 12) ----------

  # :telegram_ping → format + send via the configured telegram_sender. Result
  # propagates so Oban retries on transient failures (worker max_attempts: 5).
  # :telegram_digest and :silent → no-op; the decision row is already the audit
  # log (Step 13's cron will drain digest rows from email_routing_decisions).
  defp deliver(:telegram_ping, record, doc) do
    ping_input = build_ping_input(record, doc)
    text = TelegramFormatter.format_routing_ping(ping_input)

    case telegram_sender().(resolve_chat_id(), text) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp deliver(_action, _record, _doc), do: :ok

  defp build_ping_input(record, doc) do
    sender_email = (doc.source_metadata || %{})["sender"] || ""

    sender_name =
      case sender_email do
        "" ->
          nil

        email ->
          # email_senders row provides the curated name; missing row → nil.
          # Step 12 design: doc.source_metadata["sender_name"] fallback is
          # intentionally deferred (see future ping-formatter refinements).
          case Repo.get_by(EmailSender, email: email) do
            nil -> nil
            sender -> sender.name
          end
      end

    %{
      sender: sender_email,
      sender_name: sender_name,
      subject: doc.title || (doc.source_metadata || %{})["subject"] || "",
      urgency: record.urgency,
      summary: record.summary,
      topic: record.topic || [],
      sender_type: record.sender_type
    }
  end

  # Test seam: tests inject a 2-arity fn via Application config.
  # Default wraps Kerf.Channels.Telegram.send_message/3 to the (chat_id, text)
  # signature. Closure ignores send_message/3's opts arg (default []).
  defp telegram_sender do
    Application.get_env(:kerf, __MODULE__, [])[:telegram_sender] ||
      (&Kerf.Channels.Telegram.send_message(&1, &2))
  end

  # Reuses TELEGRAM_ALERT_CHAT_ID for v1. If triage and operational
  # notifications need different channels later, introduce TELEGRAM_TRIAGE_CHAT_ID
  # without breaking config compatibility (fall back to alert_chat_id when unset).
  defp resolve_chat_id do
    Application.get_env(:kerf, Kerf.Monitor.Alerting, [])[:telegram_chat_id]
  end

  # ---------- config snapshot ----------

  # Resolves the RoutingConfig GenServer name. Tests inject a per-test fixture
  # instance via Application config; production uses the default registered
  # module name.
  defp current_config do
    name =
      Application.get_env(:kerf, __MODULE__, [])[:routing_config_name] ||
        RoutingConfig

    RoutingConfig.current(name)
  end
end
