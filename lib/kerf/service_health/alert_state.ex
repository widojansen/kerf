defmodule Kerf.ServiceHealth.AlertState do
  @moduledoc """
  Pure state-transition function — the Kerf port of the mutations in the legacy
  `main()` (`docs/specs/izimonitoring_legacy/health_monitor.py`). See
  `docs/specs/SPEC_02_ALERT_STATE_MACHINE.md`.

  `advance/4` folds a poll outcome into the prior state and returns
  `{next_state, signals}` where `signals = %{unreachable_alert: boolean()}`.

  Dispatch is on the fetch outcome (the `decision` arg is meaningless on the
  failure path):

    * `{:error, _}` — failure path. `consecutive_failures + 1`; once
      `>= 3`, `unreachable_alert: true` AND `last_alert_time` set to `now`,
      EVERY poll (Python re-alerts each failed poll past the threshold).
      `last_alert_status` is left UNCHANGED (the preserved asymmetry).
    * `{:ok, ctx}` — success path. `consecutive_failures -> 0`. If `decision`
      fired an alert: `last_alert_status -> reason`, `last_alert_time -> now`.
      Else if `status == "healthy"`: `consecutive_healthy + 1`, and if
      `last_alert_status ∉ {nil, :healthy, :recovered}` reset it to `:healthy`.

  `now` is a trailing defaulted argument for deterministic tests.
  `consecutive_healthy` is telemetry only — written, never a decision input.
  """

  alias Kerf.ServiceHealth.{AlertDecision, Context}

  @type t :: %{
          last_alert_status: AlertDecision.reason() | nil,
          last_alert_time: DateTime.t() | nil,
          consecutive_healthy: non_neg_integer(),
          consecutive_failures: non_neg_integer()
        }
  @type fetch_outcome :: {:ok, Context.t()} | {:error, term()}
  @type decision :: {boolean(), AlertDecision.reason()}
  @type signals :: %{unreachable_alert: boolean()}

  @doc """
  Advance the state machine by one poll. Returns `{next_state, signals}`.
  """
  @spec advance(t(), fetch_outcome(), decision() | nil, DateTime.t()) :: {t(), signals()}
  def advance(prior, outcome, decision, now \\ DateTime.utc_now())

  def advance(_prior, _outcome, _decision, _now) do
    raise "not implemented: AlertState.advance/4"
  end
end
