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
  """
  use Mix.Task

  alias Kerf.Repo
  alias Kerf.ServiceHealth.State

  @target "izi2connect"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {_opts, args, _} = OptionParser.parse(argv, strict: [])

    path =
      case args do
        [path | _] -> path
        [] -> Mix.raise("usage: mix kerf.migrate_monitoring_state <path/to/state.json>")
      end

    Mix.Task.run("app.start")

    case migrate(path) do
      {:ok, %{before: before_row, after: after_row}} ->
        Mix.shell().info("Conversion: last_alert_time via round(value * 1_000_000) µs (NOT truncated).")
        Mix.shell().info("BEFORE: #{describe(before_row)}")
        Mix.shell().info("AFTER:  #{describe(after_row)}")
        :ok

      {:error, reason} ->
        Mix.raise("migration failed: #{inspect(reason)}")
    end
  end

  @doc """
  Read the `state.json` at `path`, convert, and upsert the monitoring_state row.
  Returns `{:ok, %{before: row | nil, after: row}}` or `{:error, reason}`.
  """
  @spec migrate(Path.t()) :: {:ok, map()} | {:error, term()}
  def migrate(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      attrs = %{
        target: @target,
        last_alert_status: Map.get(json, "last_alert_status"),
        last_alert_time: epoch_to_datetime(Map.get(json, "last_alert_time")),
        consecutive_healthy: Map.get(json, "consecutive_healthy", 0),
        consecutive_failures: Map.get(json, "consecutive_failures", 0)
      }

      before_row = Repo.get_by(State, target: @target)

      case upsert(before_row, attrs) do
        {:ok, row} -> {:ok, %{before: before_row, after: row}}
        {:error, changeset} -> {:error, {:invalid_state, changeset}}
      end
    end
  end

  @doc """
  Convert a Unix epoch (float/integer) to `utc_datetime_usec`, preserving
  sub-second precision via `round(value * 1_000_000)`. `nil`/`0`/`0.0` -> `nil`.
  """
  @spec epoch_to_datetime(number() | nil) :: DateTime.t() | nil
  def epoch_to_datetime(nil), do: nil
  def epoch_to_datetime(value) when is_number(value) and value == 0, do: nil

  def epoch_to_datetime(value) when is_number(value) do
    micros = round(value * 1_000_000)
    {:ok, dt} = DateTime.from_unix(micros, :microsecond)
    dt
  end

  # --- internal ---

  # Keyed on the unique target: update the existing row, or insert if none yet.
  defp upsert(nil, attrs), do: %State{} |> State.changeset(attrs) |> Repo.insert()
  defp upsert(%State{} = row, attrs), do: row |> State.changeset(attrs) |> Repo.update()

  defp describe(nil), do: "(none)"

  defp describe(%State{} = row) do
    inspect(%{
      target: row.target,
      last_alert_status: row.last_alert_status,
      last_alert_time: row.last_alert_time,
      consecutive_healthy: row.consecutive_healthy,
      consecutive_failures: row.consecutive_failures
    })
  end
end
