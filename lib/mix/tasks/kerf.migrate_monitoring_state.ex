defmodule Mix.Tasks.Kerf.MigrateMonitoringState do
  @shortdoc "One-off: migrate izimonitoring state.json into the monitoring_state row"
  @moduledoc """
  Spec 4 Phase 1 — one-off migration of the legacy izimonitoring `state.json`
  into the Kerf `monitoring_state` row (`target: "izi2connect"`). See
  `docs/specs/SPEC_04_CUTOVER.md`. NOT part of the worker.

  ## Usage

      MIX_ENV=prod mix kerf.migrate_monitoring_state /path/to/state.json

  Reads the `state.json` at the given path (no hardcoded path, no embedded data),
  converts `last_alert_time` (a Unix epoch float, e.g. `1779753602.11`) to a
  `utc_datetime_usec`, and upserts the `monitoring_state` row via
  `Kerf.ServiceHealth.State.changeset/2` (so the 5-known-status + nil validation
  applies; an out-of-set status surfaces a clear error, never a silent bad write).

  ## Timestamp conversion — ROUND, not truncate

  `last_alert_time` carries sub-second precision. We convert to integer
  microseconds with `round(value * 1_000_000)` (NOT `trunc/1`) and then
  `DateTime.from_unix(micros, :microsecond)`, so the fractional second is
  preserved and a half-microsecond rounds up rather than being silently dropped.
  The rounding choice is printed in the task output. `last_alert_time` that is
  absent / null / `0` maps to `nil`.

  Idempotent: re-running with the same `state.json` produces the same row (keyed
  on the unique `target`). Prints the BEFORE and AFTER rows.

  RED SKELETON: bodies raise; GREEN implements.
  """
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    raise "not implemented: MigrateMonitoringState.run/1"
  end

  @doc """
  Read the `state.json` at `path`, convert, and upsert the monitoring_state row.
  Returns `{:ok, %{before: row | nil, after: row}}` or `{:error, reason}`.
  """
  @spec migrate(Path.t()) :: {:ok, map()} | {:error, term()}
  def migrate(_path) do
    raise "not implemented: MigrateMonitoringState.migrate/1"
  end

  @doc """
  Convert a Unix epoch (float/integer) to `utc_datetime_usec`, preserving
  sub-second precision via `round(value * 1_000_000)`. `nil`/`0`/`0.0` -> `nil`.
  """
  @spec epoch_to_datetime(number() | nil) :: DateTime.t() | nil
  def epoch_to_datetime(_value) do
    raise "not implemented: MigrateMonitoringState.epoch_to_datetime/1"
  end
end
