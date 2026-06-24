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
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [python_tz: :string])

    {kerf_path, python_path} =
      case args do
        [k, p | _] -> {k, p}
        _ -> Mix.raise("usage: mix kerf.diff_monitor_logs <kerf_log> <python_log> [--python-tz TZ]")
      end

    tz = Keyword.get(opts, :python_tz, "Europe/Amsterdam")

    summary =
      diff(
        parse_kerf(File.read!(kerf_path)),
        parse_python(File.read!(python_path), tz)
      )

    print_summary(summary)
    :ok
  end

  @doc "Parse the Kerf log: select `[monitoring]` lines, parse our own key=value (incl ts=), ignore any backend prefix."
  @spec parse_kerf(binary()) :: [record()]
  def parse_kerf(log) do
    log
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "[monitoring]"))
    |> Enum.map(fn line ->
      %{
        ts_utc: parse_iso8601(field(line, "ts")),
        fetch: to_fetch(field(line, "fetch")),
        status: normalize_status(field(line, "status")),
        alert?: to_bool(field(line, "alert")),
        reason: to_reason(field(line, "reason"))
      }
    end)
  end

  @doc """
  Parse the Python `monitor.log`: keep only the 3 decision lines, filter all noise,
  parse asctime (`YYYY-MM-DD HH:MM:SS,mmm`) as `tz`-local and convert to UTC.
  """
  @spec parse_python(binary(), String.t()) :: [record()]
  def parse_python(log, tz \\ "Europe/Amsterdam")

  def parse_python(log, tz) do
    log
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_python_line(&1, tz))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Bucket both record lists into 5-min slots: `div(unix_utc_seconds, 300)`."
  @spec align([record()], [record()]) :: %{integer() => {record() | nil, record() | nil}}
  def align(kerf, python) do
    by_slot = fn records -> Map.new(records, fn r -> {slot(r), r} end) end
    k = by_slot.(kerf)
    p = by_slot.(python)

    (Map.keys(k) ++ Map.keys(p))
    |> Enum.uniq()
    |> Map.new(fn s -> {s, {Map.get(k, s), Map.get(p, s)}} end)
  end

  @doc "Compare aligned slots; return the divergence + missing-slot summary."
  @spec diff([record()], [record()]) :: summary()
  def diff(kerf, python) do
    aligned = align(kerf, python)
    init = %{slots_compared: 0, matches: 0, divergences: [], kerf_missing: [], python_missing: []}

    aligned
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(init, fn s, acc ->
      case Map.fetch!(aligned, s) do
        {nil, p} when not is_nil(p) ->
          %{acc | kerf_missing: acc.kerf_missing ++ [s]}

        {k, nil} when not is_nil(k) ->
          %{acc | python_missing: acc.python_missing ++ [s]}

        {k, p} ->
          acc = %{acc | slots_compared: acc.slots_compared + 1}

          case compare(k, p) do
            :match ->
              %{acc | matches: acc.matches + 1}

            {:divergence, kind} ->
              %{acc | divergences: acc.divergences ++ [%{slot: s, kerf: k, python: p, kind: kind}]}
          end
      end
    end)
  end

  # --- comparison ---

  # Compare fetch always; status/alert?/reason only when BOTH sides carry the
  # field (nil = absent). On a fetch=error slot Python carries no status/alert/
  # reason, so only fetch is compared — the known unreachable blind spot.
  defp compare(k, p) do
    cond do
      k.fetch != p.fetch -> {:divergence, :alert_mismatch}
      both?(k.status, p.status) and k.status != p.status -> {:divergence, :status_mismatch}
      both?(k.alert?, p.alert?) and k.alert? != p.alert? -> {:divergence, :alert_mismatch}
      both?(k.reason, p.reason) and k.reason != p.reason -> {:divergence, :reason_mismatch}
      true -> :match
    end
  end

  defp both?(a, b), do: not is_nil(a) and not is_nil(b)

  defp slot(%{ts_utc: %DateTime{} = dt}), do: div(DateTime.to_unix(dt), 300)

  # --- Kerf field parsing (regex per key; payload may contain spaces/quotes) ---

  defp field(line, key) do
    case Regex.run(~r/\b#{key}=(\S+)/, line) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp to_fetch("ok"), do: :ok
  defp to_fetch("error"), do: :error
  defp to_fetch(_), do: nil

  defp normalize_status(nil), do: nil
  defp normalize_status("-"), do: nil
  defp normalize_status(status), do: status

  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(_), do: nil

  defp to_reason(nil), do: nil
  # Our own bounded log vocabulary; to_atom avoids load-order fragility for a one-off tool.
  defp to_reason(value), do: String.to_atom(value)

  # --- Python line parsing ---

  defp parse_python_line(line, tz) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d{3}) \S+ (.*)$/, line) do
      [_, dt_str, ms_str, message] ->
        case classify_python(message) do
          nil -> nil
          partial -> Map.put(partial, :ts_utc, python_ts_to_utc(dt_str, ms_str, tz))
        end

      _ ->
        nil
    end
  end

  defp classify_python(message) do
    cond do
      match = Regex.run(~r/^No alert \(status: (.+)\)$/, message) ->
        [_, status] = match
        %{fetch: :ok, status: status, alert?: false, reason: :healthy}

      match = Regex.run(~r/^Alert sent: (\w+)$/, message) ->
        [_, reason] = match
        %{fetch: :ok, status: nil, alert?: true, reason: String.to_atom(reason)}

      Regex.match?(~r/^Health fetch failed \(\d+ consecutive\)$/, message) ->
        %{fetch: :error, status: nil, alert?: nil, reason: nil}

      true ->
        nil
    end
  end

  defp python_ts_to_utc(dt_str, ms_str, tz) do
    micros = String.to_integer(ms_str) * 1000

    iso =
      String.replace(dt_str, " ", "T") <>
        "." <> String.pad_leading(Integer.to_string(micros), 6, "0")

    {:ok, naive} = NaiveDateTime.from_iso8601(iso)

    naive
    |> DateTime.from_naive!(tz)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  # --- output ---

  defp print_summary(summary) do
    shell = Mix.shell()

    shell.info(
      "slots_compared=#{summary.slots_compared} matches=#{summary.matches} " <>
        "divergences=#{length(summary.divergences)} " <>
        "kerf_missing=#{length(summary.kerf_missing)} python_missing=#{length(summary.python_missing)}"
    )

    Enum.each(summary.divergences, fn d ->
      shell.info("DIVERGENCE slot=#{d.slot} kind=#{d.kind} kerf=#{inspect(d.kerf)} python=#{inspect(d.python)}")
    end)

    if summary.kerf_missing != [] do
      shell.error("KERF MISSING SLOTS (scheduling red flag — Oban/Cron): #{inspect(summary.kerf_missing)}")
    end

    if summary.python_missing != [] do
      shell.info("python missing slots (note): #{inspect(summary.python_missing)}")
    end

    if summary.kerf_missing != [] and summary.python_missing != [] do
      shell.info(
        "NOTE: a kerf_missing[N] paired with a python_missing[N±1] is likely a 5-min " <>
          "slot-boundary artifact (clock jitter), not a real gap."
      )
    end

    :ok
  end
end
