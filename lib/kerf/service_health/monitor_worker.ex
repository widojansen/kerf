defmodule Kerf.ServiceHealth.MonitorWorker do
  @moduledoc """
  Scheduled, LOG-ONLY monitoring worker — the Kerf port of the Python `main()`
  (`docs/specs/izimonitoring_legacy/health_monitor.py`). See
  `docs/specs/SPEC_03_MONITOR_WORKER.md`.

  One `perform/1`: load the `monitoring_state` row for target "izi2connect",
  fetch via `Client`, branch on outcome (`{:error,_}` failure/unreachable path
  vs `{:ok, %Context{}}` decision path through `AlertDecision`/`AlertState`),
  compose + LOG the alert payload, and persist the next state. It does NOT send
  Telegram — that flip is Spec 4. It consumes the Spec-2 `advance/4` shape
  `{next_state, %{unreachable_alert: boolean()}}` (matching `%{unreachable_alert: true}`).

  `max_attempts: 1` — a missed poll self-heals on the next 5-minute cron tick,
  and the unreachable path WANTS to count a genuine failure rather than have
  Oban retry it away (Spec 1's Client already retries transient errors).

  DI seams resolved from `Application.get_env(:kerf, __MODULE__)` (Oban args are
  JSON, so no function refs): `:fetch_fn`, `:llm_fn`, `:telegram_fn` (held but
  NEVER invoked this spec — log-only), `:now`. State load/store is Repo-backed.

  RED SKELETON: body raises; GREEN implements.
  """

  use Oban.Worker, queue: :monitoring, max_attempts: 1

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{} = _job) do
    raise "not implemented: MonitorWorker.perform/1"
  end
end
