defmodule Kerf.Agents.EmailTriage.TelegramFormatter do
  @moduledoc """
  Renders triage results as Telegram messages.
  """

  # Telegram hard message limit; the digest over-length guard keeps output within it.
  @telegram_limit 4096

  @doc """
  Format a high-priority triage result as a full Telegram message.
  """
  def format_high_priority(result) do
    sender = result.sender_info
    cls = result.classification
    stars = String.duplicate("⭐", cls.priority)
    category = cls.category |> to_string() |> String.capitalize()

    interests =
      case cls.interest_matches do
        [_ | _] = matches ->
          topics = Enum.map_join(matches, ", ", fn m ->
            "#{m.topic} (#{Float.round(m.score, 2)})"
          end)
          "Interests: #{topics}\n\n"

        _ ->
          ""
      end

    """
    📨 New email from #{sender.name || sender.email} (#{sender.email})
    Subject: #{result.subject}

    Priority: #{stars} (#{cls.priority}/5) | Category: #{category}
    #{interests}Summary: #{cls.summary}
    """
    |> String.trim()
  end

  @doc """
  Format a batch of low-priority results as a digest message.
  Returns nil for empty list.
  """
  def format_digest([]), do: nil

  def format_digest(results) do
    total = length(results)

    grouped =
      results
      |> Enum.group_by(fn r -> r.classification.category end)
      |> Enum.map(fn {category, items} ->
        label = category |> to_string() |> String.capitalize()
        names = items |> Enum.map(fn r -> r.sender_info.name || r.sender_info.email end)
        "#{label} (#{length(items)}): #{Enum.join(names, ", ")}"
      end)
      |> Enum.join("\n")

    """
    📬 Email Digest (#{total} new emails)

    #{grouped}

    No action needed. Reply /digest for full list.
    """
    |> String.trim()
  end

  @doc """
  Format a Router-triggered routing-ping message (Step 12).

  Input is a flat map built by the Router at the call site (TriageRecord +
  Document + email_senders → projection). The new vocabulary (urgency,
  topic, sender_type) replaces the Phase B classification.priority +
  interest_matches model used by `format_high_priority/1`.

  Missing-field handling:
    * `sender_name: nil` or `""` → email only, no name decoration
    * `topic: []` or `nil`      → omit the `| Topic: ...` segment
    * `sender_type: nil` or `""` → omit the "Sender type: ..." line entirely
  """
  def format_routing_ping(ping) when is_map(ping) do
    parts =
      [
        format_sender_line(ping),
        "Subject: #{ping.subject}",
        "",
        format_urgency_topic_line(ping)
      ] ++
        format_sender_type_line(ping) ++
        ["Summary: #{ping.summary}"]

    Enum.join(parts, "\n")
  end

  defp format_sender_line(%{sender_name: name, sender: email}) when name in [nil, ""],
    do: "📨 New email from #{email}"

  defp format_sender_line(%{sender_name: name, sender: email}),
    do: "📨 New email from #{name} (#{email})"

  defp format_urgency_topic_line(%{urgency: urgency, topic: topic}) do
    emoji = urgency_emoji(urgency)
    urgency_part = String.trim("Urgency: #{emoji} #{urgency}")

    case topic do
      list when is_list(list) and list != [] ->
        "#{urgency_part} | Topic: #{Enum.join(list, ", ")}"

      _ ->
        urgency_part
    end
  end

  # 🚨 high, ⚠️ medium, ℹ️ low; "none" and unknown values render emoji-less.
  defp urgency_emoji("high"), do: "🚨"
  defp urgency_emoji("medium"), do: "⚠️"
  defp urgency_emoji("low"), do: "ℹ️"
  defp urgency_emoji(_), do: ""

  defp format_sender_type_line(%{sender_type: type}) when type in [nil, ""], do: []
  defp format_sender_type_line(%{sender_type: type}),
    do: ["Sender type: #{humanize_sender_type(type)}"]

  defp humanize_sender_type("known_priority"), do: "Priority sender"
  defp humanize_sender_type("known_routine"), do: "Familiar sender"
  defp humanize_sender_type("unknown_human"), do: "New sender"
  defp humanize_sender_type("automated_system"), do: "Automated"
  defp humanize_sender_type(other), do: other

  @doc """
  Format a digest message from a list of flat-map items (Step 13 + SPEC B).

  `transactional` items are itemised inline — one line per email, newest-first,
  `HH:MM  sender — subject` (HH:MM in the configured display tz, sender/subject
  truncated) — capped at `transactional_inline_cap` with a `… +M more` note.
  Every other category renders as a count line (up to 3 names + `+N more`),
  placed after the transactional block. A non-empty digest with no
  transactional emails shows `📑 Transactional: none`.

  Item shapes:
    - transactional: `%{category: "transactional", sender:, subject:, timestamp:}`
    - other:         `%{name: String.t(), category: String.t()}`

  Empty input returns `nil` — the worker uses this to skip the Telegram send.
  The over-length guard keeps output within `@telegram_limit`, trimming the
  transactional block further (ending with `… +M more`) rather than cutting
  a line mid-way. When the transactional list overflows, the `/digest_full`
  footer is omitted — the `+M more` note is the honest signal until item L.
  """
  def format_routing_digest(items, opts \\ [])
  def format_routing_digest([], _opts), do: nil

  def format_routing_digest(items, opts) when is_list(items) do
    total = length(items)
    since_label = Keyword.get(opts, :since_label, "")

    header_suffix =
      if since_label != "", do: ", #{since_label} since last", else: ""

    {transactional, others} =
      Enum.split_with(items, fn i -> Map.get(i, :category) == "transactional" end)

    sorted_txns = Enum.sort_by(transactional, & &1.timestamp, {:desc, DateTime})
    others_block = render_other_categories(others)

    assemble_digest(
      total,
      header_suffix,
      sorted_txns,
      others_block,
      min(transactional_cap(), length(sorted_txns))
    )
  end

  # Render at `shown_limit` transactional lines; shrink until within the Telegram
  # limit, then stop (the last shown line is never cut mid-way).
  defp assemble_digest(total, suffix, sorted_txns, others_block, shown_limit) do
    {txn_block, overflow?} = render_transactional(sorted_txns, shown_limit)
    text = build_digest_text(total, suffix, txn_block, others_block, overflow?)

    cond do
      String.length(text) <= @telegram_limit -> text
      shown_limit > 1 -> assemble_digest(total, suffix, sorted_txns, others_block, shown_limit - 1)
      true -> text
    end
  end

  defp build_digest_text(total, suffix, txn_block, others_block, overflow?) do
    body =
      [txn_block, others_block]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    footer =
      if overflow?,
        do: "",
        else: "\n\nReply /digest_full for details. (Feature not yet implemented.)"

    ("📬 Email Digest (#{total} emails#{suffix})\n\n" <> body <> footer)
    |> String.trim()
  end

  # Empty transactional on an otherwise-sent digest: absence is information.
  defp render_transactional([], _shown_limit), do: {"📑 Transactional: none", false}

  defp render_transactional(sorted, shown_limit) do
    total = length(sorted)
    shown = Enum.take(sorted, shown_limit)
    lines = Enum.map(shown, &transactional_line/1)
    remaining = total - length(shown)

    {more_lines, overflow?} =
      if remaining > 0, do: {["  … +#{remaining} more"], true}, else: {[], false}

    block = Enum.join(["📑 Transactional (#{total})" | lines] ++ more_lines, "\n")
    {block, overflow?}
  end

  defp transactional_line(item) do
    hhmm = format_local_time(item.timestamp)
    sender = truncate(item.sender, 30)
    subject = truncate(item.subject, 50)
    "  • #{hhmm}  #{sender} — #{subject}"
  end

  defp format_local_time(%DateTime{} = utc) do
    case DateTime.shift_zone(utc, display_tz()) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M")
      {:error, _} -> Calendar.strftime(utc, "%H:%M")
    end
  end

  defp truncate(value, max) do
    str = to_string(value)
    if String.length(str) > max, do: String.slice(str, 0, max - 1) <> "…", else: str
  end

  defp render_other_categories([]), do: ""

  defp render_other_categories(others) do
    others
    |> Enum.group_by(& &1.category)
    |> Enum.map_join("\n", fn {category, group_items} ->
      format_category_group(category, group_items)
    end)
  end

  # Defensive config reads (spec defaults); `:kerf, :digest` may be unset in prod.
  defp digest_config, do: Application.get_env(:kerf, :digest, [])
  defp display_tz, do: Keyword.get(digest_config(), :display_tz, "Europe/Amsterdam")
  defp transactional_cap, do: Keyword.get(digest_config(), :transactional_inline_cap, 40)

  defp format_category_group(category, items) do
    count = length(items)
    label = category |> to_string() |> String.capitalize()

    names = Enum.map(items, & &1.name)
    displayed = Enum.take(names, 3)
    rest = max(0, count - 3)

    names_str =
      case rest do
        0 -> Enum.join(displayed, ", ")
        n -> Enum.join(displayed, ", ") <> ", +#{n} more"
      end

    "#{label} (#{count}): #{names_str}"
  end

  @doc """
  Generate ApprovalGate button specs for a high-priority result.
  """
  def approval_buttons(result) do
    doc_id = result.document_id

    [
      %{label: "Follow up", callback_data: "email_triage:follow_up:#{doc_id}"},
      %{label: "Archive", callback_data: "email_triage:archive:#{doc_id}"},
      %{label: "Add sender to priority", callback_data: "email_triage:add_priority:#{doc_id}"}
    ]
  end
end
