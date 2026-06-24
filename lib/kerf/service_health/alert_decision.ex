defmodule Kerf.ServiceHealth.AlertDecision do
  @moduledoc """
  Pure alert-decision function — the Kerf port of the legacy `should_alert`
  (`docs/specs/izimonitoring_legacy/health_monitor.py`). See
  `docs/specs/SPEC_02_ALERT_STATE_MACHINE.md`.

  Five outcomes, evaluated top-to-bottom, first match wins:

    1. `status == "critical"`                                                 -> `{true, :critical}`
    2. `warning` AND (`is_anomalous` OR `anomalies` non-empty)                 -> `{true, :anomaly}`
    3. `warning` AND `alerts` non-empty AND `now - last_alert_time > 1800`     -> `{true, :warning}`
    4. `healthy` AND `last_alert_status ∈ {:critical, :anomaly, :warning}`     -> `{true, :recovered}`
    -. otherwise                                                              -> `{false, :healthy}`

  `now` is a trailing defaulted argument so the throttle boundary (strict `>`,
  exactly 1800s = no fire) is deterministically testable. `nil` `last_alert_time`
  is treated as infinitely stale (Rule 3 fires) — matches Python's
  `state.get("last_alert_time", 0)` always-stale default.
  """

  alias Kerf.ServiceHealth.Context

  @type reason :: :critical | :anomaly | :warning | :recovered | :healthy
  @type state :: %{
          optional(:last_alert_status) => reason() | nil,
          optional(:last_alert_time) => DateTime.t() | nil,
          optional(atom()) => any()
        }

  @doc """
  Decide whether to alert for `context` given the prior `state`. Returns
  `{alert?, reason}`. `now` defaults to the wall clock; pass a fixed value in tests.
  """
  @spec should_alert(Context.t(), state(), DateTime.t()) :: {boolean(), reason()}
  def should_alert(context, state, now \\ DateTime.utc_now())

  def should_alert(_context, _state, _now) do
    raise "not implemented: AlertDecision.should_alert/3"
  end
end
