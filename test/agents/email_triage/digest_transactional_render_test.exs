defmodule Kerf.Agents.EmailTriage.DigestTransactionalRenderTest do
  # SPEC B — RED. Itemised transactional block in the digest renderer.
  #
  # async: false because case (l) mutates `Application.get_env(:kerf, :digest)`
  # to prove the defensive config fallback; a shared global env must not race
  # sibling tests. Pure string rendering otherwise (seed-stable).
  use ExUnit.Case, async: false

  alias Kerf.Agents.EmailTriage.TelegramFormatter

  # Telegram hard cap; the over-limit guard (§2) must keep output within this.
  @telegram_limit 4096

  # A transactional digest item carries sender + subject + UTC timestamp
  # (per the reconciled projection contract), NOT the legacy %{name, category}.
  defp txn(sender, subject, %DateTime{} = ts) do
    %{category: "transactional", sender: sender, subject: subject, timestamp: ts}
  end

  describe "format_routing_digest/2 — transactional itemisation (SPEC B)" do
    test "(e) K transactional items → one HH:MM · sender — subject line each, local tz" do
      items = [
        txn("mijndomein.nl", "Factuur 2026-07 beschikbaar", ~U[2026-07-02 07:14:00Z]),
        txn("bol.com", "Je bestelling is verzonden", ~U[2026-07-02 06:02:00Z])
      ]

      text = TelegramFormatter.format_routing_digest(items, since_label: "2h")

      assert is_binary(text)
      assert text =~ "mijndomein.nl"
      assert text =~ "Factuur 2026-07 beschikbaar"
      assert text =~ "bol.com"
      assert text =~ "Je bestelling is verzonden"
      # 07:14Z → 09:14 and 06:02Z → 08:02 in Europe/Amsterdam (CEST, +2 in July)
      assert text =~ "09:14"
      assert text =~ "08:02"
      # exactly one item line per transactional record
      assert length(Regex.scan(~r/\d{2}:\d{2}/, text)) == 2
    end

    test "(f) other categories still render as 3-name + '+N more' count lines" do
      transactional = [txn("mijndomein.nl", "Factuur", ~U[2026-07-02 07:14:00Z])]
      newsletters = for n <- 1..8, do: %{name: "News#{n}", category: "newsletter"}

      text = TelegramFormatter.format_routing_digest(transactional ++ newsletters, since_label: "5h")

      assert text =~ ~r/newsletter.*\(8\)/i
      assert text =~ ~r/\+\s*5\s+more/
      assert text =~ "News1"
      # names past the 3-name cap collapse into the count note
      refute text =~ "News8"
    end

    test "(g) cap + E transactional records → exactly `cap` item lines + '+E more'" do
      cap = 40
      extra = 3

      items =
        for n <- 1..(cap + extra) do
          txn("s#{n}.example.com", "Subject #{n}",
              DateTime.add(~U[2026-07-02 07:00:00Z], n, :second))
        end

      text = TelegramFormatter.format_routing_digest(items, since_label: "6h")

      # exactly `cap` HH:MM item lines
      assert length(Regex.scan(~r/\d{2}:\d{2}/, text)) == cap
      assert text =~ ~r/\+\s*#{extra}\s+more/
    end

    test "(h) transactional block is ordered newest-first" do
      older = txn("old.example.com", "OLDER-EMAIL-MARKER", ~U[2026-07-02 05:00:00Z])
      newer = txn("new.example.com", "NEWER-EMAIL-MARKER", ~U[2026-07-02 08:00:00Z])

      text = TelegramFormatter.format_routing_digest([older, newer], since_label: "1h")

      {newer_pos, _} = :binary.match(text, "NEWER-EMAIL-MARKER")
      {older_pos, _} = :binary.match(text, "OLDER-EMAIL-MARKER")

      assert newer_pos < older_pos, "newest transactional must appear first"
    end

    test "(i) zero transactional on an otherwise-non-empty digest → 'Transactional: none'" do
      newsletters = for n <- 1..3, do: %{name: "News#{n}", category: "newsletter"}

      text = TelegramFormatter.format_routing_digest(newsletters, since_label: "4h")

      assert is_binary(text)
      assert text =~ "Transactional: none"
    end

    test "(j) fully empty digest still returns nil (skipped), no 'none' line" do
      assert TelegramFormatter.format_routing_digest([], since_label: "4h") == nil
    end

    test "(k) over-limit input stays within the Telegram limit and ends with '+M more'" do
      items =
        for n <- 1..200 do
          txn("sender#{n}.example.com",
              "Long subject line number #{n} about invoices and shipments and more",
              DateTime.add(~U[2026-07-02 07:00:00Z], n, :second))
        end

      text = TelegramFormatter.format_routing_digest(items, since_label: "8h")

      assert String.length(text) <= @telegram_limit
      last_line = text |> String.split("\n", trim: true) |> List.last()
      assert last_line =~ ~r/\+\s*\d+\s+more/
      # the final line is the overflow note, not a mid-line-cut item
      refute last_line =~ "—"
    end

    test "(l) config unset (:kerf, :digest → nil) renders with defaults, does not raise" do
      previous = Application.get_env(:kerf, :digest)
      Application.delete_env(:kerf, :digest)

      on_exit(fn ->
        if previous do
          Application.put_env(:kerf, :digest, previous)
        else
          Application.delete_env(:kerf, :digest)
        end
      end)

      assert Application.get_env(:kerf, :digest) == nil

      items = [txn("mijndomein.nl", "Factuur", ~U[2026-07-02 07:14:00Z])]

      text = TelegramFormatter.format_routing_digest(items, since_label: "3h")

      assert is_binary(text)
      # default display_tz "Europe/Amsterdam" + default cap 40 applied without config
      assert text =~ "09:14"
    end
  end
end
