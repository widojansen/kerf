defmodule Mix.Tasks.Kerf.DiffMonitorLogsTest do
  # Spec 4 Phase 2 — log-diff helper. Synthetic fixtures only: fabricated Kerf
  # lines WITH ts=, Python lines with asctime. NO real log data, NO prod paths.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kerf.DiffMonitorLogs, as: Diff

  @tz "Europe/Amsterdam"

  # A Kerf [monitoring] line with a (deliberately bogus) backend prefix that
  # parse_kerf must ignore — it parses our own ts= / key=value, not the prefix.
  defp kerf_line(ts_iso, fields) do
    "12:34:56.000 [warning] [monitoring] target=izi2connect ts=#{ts_iso} #{fields}"
  end

  # Kerf 12:00:00Z and Python 14:00:02 Amsterdam (CEST = UTC+2 in June) -> 12:00:02Z,
  # same div(unix, 300) slot.
  @kerf_ts "2026-06-24T12:00:00.000000Z"

  describe "parse_kerf/1" do
    test "1. parses a [monitoring] line (ignoring the backend prefix), including ts=" do
      log = kerf_line(@kerf_ts, "fetch=ok status=critical alert=true reason=critical payload=\"🔴 boom\"")

      assert [rec] = Diff.parse_kerf(log)
      assert rec.ts_utc == ~U[2026-06-24 12:00:00.000000Z]
      assert rec.fetch == :ok
      assert rec.status == "critical"
      assert rec.alert? == true
      assert rec.reason == :critical
    end
  end

  describe "parse_python/2" do
    test "2. selects only the 3 decision lines and filters ALL noise" do
      log = """
      2026-06-24 14:00:02,110 INFO No alert (status: healthy)
      2026-06-24 14:05:01,200 INFO LLM summary generated: blah blah
      2026-06-24 14:05:01,300 INFO Telegram sent: 🔴 something
      2026-06-24 14:05:01,400 INFO Alert sent: critical
      2026-06-24 14:10:30,000 ERROR Failed to fetch health: timeout
      2026-06-24 14:10:30,400 WARNING Health fetch failed (3 consecutive)
      """

      recs = Diff.parse_python(log, @tz)

      assert length(recs) == 3
      assert Enum.any?(recs, &(&1.status == "healthy" and &1.alert? == false and &1.reason == :healthy))
      assert Enum.any?(recs, &(&1.alert? == true and &1.reason == :critical and is_nil(&1.status)))
      assert Enum.any?(recs, &(&1.fetch == :error))
    end

    test "3. converts asctime from --python-tz to UTC" do
      log = "2026-06-24 14:00:02,110 INFO No alert (status: healthy)"

      assert [rec] = Diff.parse_python(log, @tz)
      # 14:00:02 Amsterdam (CEST, UTC+2) -> 12:00:02 UTC
      assert rec.ts_utc == ~U[2026-06-24 12:00:02.110000Z]
    end
  end

  describe "align/2" do
    test "10. an Amsterdam Python line and a UTC Kerf line bucket into the SAME slot" do
      kerf = Diff.parse_kerf(kerf_line(@kerf_ts, "fetch=ok status=healthy alert=false reason=healthy"))
      python = Diff.parse_python("2026-06-24 14:00:02,110 INFO No alert (status: healthy)", @tz)

      aligned = Diff.align(kerf, python)

      assert map_size(aligned) == 1
      assert [{_slot, {k, p}}] = Map.to_list(aligned)
      refute is_nil(k)
      refute is_nil(p)
    end
  end

  describe "diff/2" do
    test "4. clean all-match" do
      kerf = Diff.parse_kerf(kerf_line(@kerf_ts, "fetch=ok status=healthy alert=false reason=healthy"))
      python = Diff.parse_python("2026-06-24 14:00:02,110 INFO No alert (status: healthy)", @tz)

      summary = Diff.diff(kerf, python)

      assert summary.matches == 1
      assert summary.divergences == []
      assert summary.kerf_missing == []
      assert summary.python_missing == []
    end

    test "5. status-only divergence on a no-alert slot" do
      kerf = Diff.parse_kerf(kerf_line(@kerf_ts, "fetch=ok status=healthy alert=false reason=healthy"))
      python = Diff.parse_python("2026-06-24 14:00:02,110 INFO No alert (status: warning)", @tz)

      summary = Diff.diff(kerf, python)

      assert [%{kind: :status_mismatch}] = summary.divergences
      assert summary.matches == 0
    end

    test "6. alert/reason divergence on an alert slot" do
      kerf = Diff.parse_kerf(kerf_line(@kerf_ts, "fetch=ok status=critical alert=true reason=critical payload=\"🔴 x\""))
      python = Diff.parse_python("2026-06-24 14:00:02,110 INFO Alert sent: anomaly", @tz)

      summary = Diff.diff(kerf, python)

      assert [%{kind: :reason_mismatch}] = summary.divergences
    end

    test "7. kerf_missing slot (the scheduling red flag)" do
      kerf = Diff.parse_kerf("")
      python = Diff.parse_python("2026-06-24 14:00:02,110 INFO No alert (status: healthy)", @tz)

      summary = Diff.diff(kerf, python)

      assert length(summary.kerf_missing) == 1
      assert summary.python_missing == []
    end

    test "8. python_missing slot (a note, not a red flag)" do
      kerf = Diff.parse_kerf(kerf_line(@kerf_ts, "fetch=ok status=healthy alert=false reason=healthy"))
      python = Diff.parse_python("", @tz)

      summary = Diff.diff(kerf, python)

      assert length(summary.python_missing) == 1
      assert summary.kerf_missing == []
    end

    test "9. unreachable blind-spot: both fetch=error -> matched on fetch, absent Python reason NOT flagged" do
      kerf = Diff.parse_kerf(kerf_line(@kerf_ts, "fetch=error status=- alert=true reason=unreachable payload=\"🚨 x\""))
      python = Diff.parse_python("2026-06-24 14:00:02,110 WARNING Health fetch failed (3 consecutive)", @tz)

      summary = Diff.diff(kerf, python)

      assert summary.matches == 1
      assert summary.divergences == []
    end
  end
end
