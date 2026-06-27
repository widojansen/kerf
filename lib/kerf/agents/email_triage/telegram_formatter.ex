defmodule Kerf.Agents.EmailTriage.TelegramFormatter do
  @moduledoc """
  Renders triage results as Telegram messages.
  """

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
  Format a digest message from a list of flat-map items (Step 13).

  Input shape per item: `%{name: String.t(), category: String.t()}`.
  Grouped by category. Each category lists up to 3 names; the rest collapse
  to `+N more`. Empty input returns `nil` — the worker uses this as a signal
  to skip the Telegram send.

  Footer references the `/digest_full` Tina command (deferred-work item L).
  """
  def format_routing_digest(items, opts \\ [])
  def format_routing_digest([], _opts), do: nil

  def format_routing_digest(items, opts) when is_list(items) do
    total = length(items)
    since_label = Keyword.get(opts, :since_label, "")

    groups_text =
      items
      |> Enum.group_by(& &1.category)
      |> Enum.map_join("\n", fn {category, group_items} ->
        format_category_group(category, group_items)
      end)

    header_suffix =
      if since_label != "", do: ", #{since_label} since last", else: ""

    """
    📬 Email Digest (#{total} emails#{header_suffix})

    #{groups_text}

    Reply /digest_full for details. (Feature not yet implemented.)
    """
    |> String.trim()
  end

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
