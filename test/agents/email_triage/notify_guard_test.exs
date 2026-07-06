defmodule Kerf.Agents.EmailTriage.NotifyGuardTest do
  # async: false — `window_configurable` mutates the module's Application env
  # (a process-global), so this file must not race other async tests.
  use ExUnit.Case, async: false

  alias Kerf.Agents.EmailTriage.NotifyGuard

  # Fixed reference instant for every guard test. All fixture dates are derived
  # from this via `at/1`, so the suite is seed-stable and clock-independent.
  @now ~U[2026-04-01 12:00:00Z]

  # RFC2822 rendering of `@now` shifted back `hours`, weekday omitted (the
  # weekday token is advisory in RFC2822; omitting it keeps fixtures free of a
  # hand-computed day-of-week). English month abbreviations come from the
  # default strftime locale.
  defp at(hours) do
    @now
    |> DateTime.add(-hours * 3600, :second)
    |> Calendar.strftime("%d %b %Y %H:%M:%S +0000")
  end

  describe "notify?/2 — self-sent silence (rule 1)" do
    test "sent_label_is_silent — SENT + recent date is silent" do
      refute NotifyGuard.notify?(%{labels: ["SENT", "INBOX"], date: at(1)}, @now)
    end

    test "sent_label_silent_without_date — SENT + nil date is silent" do
      refute NotifyGuard.notify?(%{labels: ["SENT"], date: nil}, @now)
    end
  end

  describe "notify?/2 — staleness window (rule 2)" do
    test "stale_is_silent — 48h-old inbox mail is silent" do
      refute NotifyGuard.notify?(%{labels: ["INBOX"], date: at(48)}, @now)
    end

    test "boundary_inside_window_notifies — 23h old (inside 24h) notifies" do
      assert NotifyGuard.notify?(%{labels: ["INBOX"], date: at(23)}, @now)
    end

    test "boundary_outside_window_silent — 25h old (outside 24h) is silent" do
      refute NotifyGuard.notify?(%{labels: ["INBOX"], date: at(25)}, @now)
    end

    test "recent_inbox_notifies — 1h-old inbox mail notifies" do
      assert NotifyGuard.notify?(%{labels: ["INBOX"], date: at(1)}, @now)
    end
  end

  describe "notify?/2 — fail-open on bad dates" do
    test "nil_date_non_sent_notifies — nil date on non-sent mail notifies" do
      assert NotifyGuard.notify?(%{labels: ["INBOX"], date: nil}, @now)
    end

    test "unparseable_date_non_sent_notifies — garbage date notifies" do
      assert NotifyGuard.notify?(%{labels: ["INBOX"], date: "garbage"}, @now)
    end
  end

  describe "notify?/2 — configurable window" do
    setup do
      prev = Application.get_env(:kerf, NotifyGuard)
      Application.put_env(:kerf, NotifyGuard, max_age_hours: 12)

      on_exit(fn ->
        if prev do
          Application.put_env(:kerf, NotifyGuard, prev)
        else
          Application.delete_env(:kerf, NotifyGuard)
        end
      end)
    end

    test "window_configurable — 13h old under a 12h window is silent" do
      refute NotifyGuard.notify?(%{labels: ["INBOX"], date: at(13)}, @now)
    end
  end

  describe "parse_date/1" do
    test "valid RFC2822 in UTC parses to correct UTC" do
      assert {:ok, ~U[2026-03-31 10:00:00Z]} =
               NotifyGuard.parse_date("Mon, 31 Mar 2026 10:00:00 +0000")
    end

    test "non-UTC offset is normalised to UTC" do
      assert {:ok, ~U[2026-03-31 10:00:00Z]} =
               NotifyGuard.parse_date("Mon, 31 Mar 2026 12:00:00 +0200")
    end

    test "weekday-less form is accepted" do
      assert {:ok, ~U[2026-03-31 10:00:00Z]} =
               NotifyGuard.parse_date("31 Mar 2026 10:00:00 +0000")
    end

    test "malformed input returns :error" do
      assert :error = NotifyGuard.parse_date("garbage")
    end
  end
end
