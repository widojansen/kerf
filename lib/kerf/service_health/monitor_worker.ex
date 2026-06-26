defmodule Kerf.ServiceHealth.MonitorWorker do
  @moduledoc """
  Scheduled, LOG-ONLY monitoring worker — the Kerf port of the Python `main()`
  (`docs/specs/izimonitoring_legacy/health_monitor.py`). See
  `docs/specs/SPEC_03_MONITOR_WORKER.md`.

  One `perform/1`: load the `monitoring_state` row for target "izi2connect",
  fetch via `Client`, branch on outcome (`{:error,_}` failure/unreachable path
  vs `{:ok, %Context{}}` decision path through `AlertDecision`/`AlertState`),
  compose + LOG the alert payload, and persist the next state. It consumes the
  Spec-2 `advance/4` shape `{next_state, %{unreachable_alert: boolean()}}`
  (matching `%{unreachable_alert: true}`).

  ## Live send (default OFF — the Spec-4 gate)

  The worker ALWAYS logs the alert (the audit trail). When `:live_send` is on it
  ADDITIONALLY sends the composed payload via `:telegram_fn` (default: a wrapper
  over `TelegramClient.send_message/1`). With `:live_send` off (the default) it is
  log-only and `:telegram_fn` is never invoked. Only alert / unreachable payloads
  send — routine no-alert polls never do. A send failure is logged and swallowed:
  it never fails the Oban job (self-heals on the next 5-minute tick).

  `max_attempts: 1` — a missed poll self-heals on the next cron tick, and the
  unreachable path WANTS to count a genuine failure rather than have Oban retry it
  away (Spec 1's Client already retries transient errors).

  DI seams resolved from `Application.get_env(:kerf, __MODULE__)` (Oban args are
  JSON, so no function refs): `:fetch_fn`, `:llm_fn`, `:telegram_fn`, `:now`,
  `:live_send`. State load/store is Repo-backed.
  """

  use Oban.Worker, queue: :monitoring, max_attempts: 1

  require Logger

  alias Kerf.Repo
  alias Kerf.ServiceHealth.{AlertDecision, AlertState, Client, Context, State, SummaryBuilder}

  @target "izi2connect"
  @unreachable_payload "🚨 izi-monitoring API unreachable for 15+ minutes. Check server."

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{} = _job) do
    cfg = Application.get_env(:kerf, __MODULE__, [])
    fetch_fn = cfg[:fetch_fn] || (&default_fetch/0)
    now = cfg[:now] || DateTime.utc_now()

    row = Repo.get_by!(State, target: @target)
    state = load_state(row)

    next =
      case fetch_fn.() do
        {:error, reason} -> handle_failure(state, reason, cfg, now)
        {:ok, %Context{} = context} -> handle_success(state, context, cfg, now)
      end

    persist!(row, next)
    :ok
  end

  # --- failure / unreachable path ---

  defp handle_failure(state, reason, cfg, now) do
    {next, signals} = AlertState.advance(state, {:error, reason}, nil, now)

    if signals.unreachable_alert do
      log_alert("error", "-", :unreachable, @unreachable_payload, now)
      maybe_send(@unreachable_payload, cfg)
    else
      Logger.info(
        "[monitoring] target=#{@target} ts=#{DateTime.to_iso8601(now)} fetch=error status=- " <>
          "alert=false consecutive_failures=#{next.consecutive_failures}",
        monitoring: true
      )
    end

    next
  end

  # --- success path ---

  defp handle_success(state, context, cfg, now) do
    {alert?, reason} = AlertDecision.should_alert(context, state, now)
    {next, _signals} = AlertState.advance(state, {:ok, context}, {alert?, reason}, now)

    if alert? do
      summary = SummaryBuilder.build(context, reason, summary_opts(cfg))
      payload = "#{emoji(reason)} #{summary}"
      log_alert("ok", context.status, reason, payload, now)
      maybe_send(payload, cfg)
    else
      Logger.info(
        "[monitoring] target=#{@target} ts=#{DateTime.to_iso8601(now)} fetch=ok " <>
          "status=#{context.status} alert=false reason=#{reason}",
        monitoring: true
      )
    end

    next
  end

  # --- live send (default off) ---

  # Always called AFTER log_alert, so the audit log is emitted regardless. When
  # live_send is on, additionally deliver the payload. A send failure is logged
  # and swallowed — it NEVER fails the job (return value is discarded; the caller
  # still reaches persist! and returns :ok).
  defp maybe_send(payload, cfg) do
    if cfg[:live_send] || false do
      telegram_fn = cfg[:telegram_fn] || (&default_telegram/1)

      case telegram_fn.(payload) do
        {:error, reason} ->
          Logger.error(
            "[monitoring] target=#{@target} telegram send failed: #{inspect(reason)}",
            monitoring: true
          )

        _ ->
          :ok
      end
    end

    :ok
  end

  # Alert + unreachable payloads are alert-worthy -> :warning (surfaces above the
  # routine :info polls and above the test/prod info threshold). Routine no-alert
  # and below-threshold-failure lines stay at :info.
  defp log_alert(fetch, status, reason, payload, now) do
    Logger.warning(
      "[monitoring] target=#{@target} ts=#{DateTime.to_iso8601(now)} fetch=#{fetch} " <>
        "status=#{status} alert=true reason=#{reason} payload=#{inspect(payload)}",
      monitoring: true
    )
  end

  # --- state load/store boundary (string <-> atom) ---

  defp load_state(%State{} = row) do
    %{
      last_alert_status: State.status_to_atom(row.last_alert_status),
      last_alert_time: row.last_alert_time,
      consecutive_healthy: row.consecutive_healthy,
      consecutive_failures: row.consecutive_failures
    }
  end

  defp persist!(%State{} = row, next) do
    row
    |> State.changeset(%{
      last_alert_status: State.status_to_string(next.last_alert_status),
      last_alert_time: next.last_alert_time,
      consecutive_healthy: next.consecutive_healthy,
      consecutive_failures: next.consecutive_failures
    })
    |> Repo.update!()
  end

  # --- helpers ---

  defp summary_opts(cfg) do
    case cfg[:llm_fn] do
      nil -> []
      llm_fn -> [llm_fn: llm_fn]
    end
  end

  defp emoji(:critical), do: "🔴"
  defp emoji(:anomaly), do: "⚠️"
  defp emoji(:warning), do: "⚠️"
  defp emoji(:recovered), do: "✅"

  defp default_fetch, do: Client.fetch_health_context()

  defp default_telegram(payload), do: Kerf.ServiceHealth.TelegramClient.send_message(payload)
end
