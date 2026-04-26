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
