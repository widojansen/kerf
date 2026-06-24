defmodule Mix.Tasks.Kerf.DiffMonitorLogs do
  @shortdoc "One-off: diff the Kerf [monitoring] log against the Python monitor.log"
  @moduledoc """
  Spec 4 Phase 2 — parallel-run soak comparison. Reads the Kerf worker's
  `[monitoring]` log and the legacy Python `monitor.log`, buckets both into 5-min
  slots, and reports per-slot agreement + missing slots. See
  `docs/specs/SPEC_04_CUTOVER.md`. NOT part of the worker.

  ## Usage

      mix kerf.diff_monitor_logs <kerf_log> <python_log> [--python-tz Europe/Amsterdam]

  No hardcoded paths. `--python-tz` (default `Europe/Amsterdam`) is the timezone of
  the Python `monitor.log` asctime, used to convert it to UTC before slotting.

  ## Normalized record

      %{ts_utc: DateTime.t() | nil, fetch: :ok | :error,
        status: String.t() | nil, alert?: boolean() | nil, reason: atom() | nil}

  Each source omits fields the other has, so the diff compares the INTERSECTION
  per slot: `fetch` always; `status` only when both sides have it (no-alert slots —
  the Python `Alert sent` line carries no status); `{alert?, reason}` on alert
  slots. On fetch=error slots only `fetch` is compared — Python's `monitor.log`
  has no clean per-slot unreachable-decision line, so the absent Python reason is
  the known blind spot and is NOT flagged as a divergence.

  ## Slot alignment

  Slot key = `div(unix_utc_seconds, 300)` (floor to the 5-min grid). A paired
  `kerf_missing[N]` + `python_missing[N±1]` is almost certainly a slot-boundary
  artifact (clock jitter), not a real gap; the printed output notes this.

  `kerf_missing` is the RED FLAG (Oban/Cron scheduling problem); `python_missing`
  is a note.

  RED SKELETON: bodies raise; GREEN implements.
  """
  use Mix.Task

  @type record :: %{
          ts_utc: DateTime.t() | nil,
          fetch: :ok | :error,
          status: String.t() | nil,
          alert?: boolean() | nil,
          reason: atom() | nil
        }

  @type summary :: %{
          slots_compared: non_neg_integer(),
          matches: non_neg_integer(),
          divergences: [map()],
          kerf_missing: [integer()],
          python_missing: [integer()]
        }

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    raise "not implemented: DiffMonitorLogs.run/1"
  end

  @doc "Parse the Kerf log: select `[monitoring]` lines, parse our own key=value (incl ts=), ignore any backend prefix."
  @spec parse_kerf(binary()) :: [record()]
  def parse_kerf(_log) do
    raise "not implemented: DiffMonitorLogs.parse_kerf/1"
  end

  @doc """
  Parse the Python `monitor.log`: keep only the 3 decision lines, filter all noise,
  parse asctime (`YYYY-MM-DD HH:MM:SS,mmm`) as `tz`-local and convert to UTC.
  """
  @spec parse_python(binary(), String.t()) :: [record()]
  def parse_python(log, tz \\ "Europe/Amsterdam")

  def parse_python(_log, _tz) do
    raise "not implemented: DiffMonitorLogs.parse_python/2"
  end

  @doc "Bucket both record lists into 5-min slots: `div(unix_utc_seconds, 300)`."
  @spec align([record()], [record()]) :: %{integer() => {record() | nil, record() | nil}}
  def align(_kerf, _python) do
    raise "not implemented: DiffMonitorLogs.align/2"
  end

  @doc "Compare aligned slots; return the divergence + missing-slot summary."
  @spec diff([record()], [record()]) :: summary()
  def diff(_kerf, _python) do
    raise "not implemented: DiffMonitorLogs.diff/2"
  end
end
