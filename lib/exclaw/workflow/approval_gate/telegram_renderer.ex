defmodule ExClaw.Workflow.ApprovalGate.TelegramRenderer do
  @moduledoc """
  Pure functions for building Telegram messages for approval requests.
  """

  @telegram_max_text 4096
  @max_callback_data 64

  @doc """
  Build a Telegram message with inline keyboard for an approval request.
  """
  def render_approval_message(request) do
    text = build_approval_text(request)

    buttons =
      request.options
      |> Enum.with_index()
      |> Enum.map(fn {label, index} ->
        callback_data = build_callback_data(request.request_id, index)
        %{text: label, callback_data: callback_data}
      end)

    %{
      chat_id: request.chat_id,
      text: truncate(text, @telegram_max_text),
      parse_mode: "HTML",
      reply_markup: %{
        inline_keyboard: [buttons]
      }
    }
  end

  @doc """
  Build the edited message after a decision is made.
  Removes the inline keyboard and shows the decision.
  """
  def render_decision_message(request, decision, decided_by) do
    status_line = decision_status_line(decision, decided_by)
    original_text = build_approval_text(request)

    %{
      chat_id: request.chat_id,
      message_id: request.telegram_message_id,
      text: "#{original_text}\n\n#{status_line}",
      parse_mode: "HTML",
      reply_markup: %{inline_keyboard: []}
    }
  end

  @doc """
  Build the answerCallbackQuery payload to dismiss the button spinner.
  """
  def render_callback_answer(callback_query_id, decision) do
    %{
      callback_query_id: callback_query_id,
      text: "#{decision}d"
    }
  end

  @doc """
  Parse callback_data from a Telegram callback query.
  Returns {:ok, request_id, option_index} or :ignore.
  """
  def parse_callback_data("ag:" <> rest) do
    case String.split(rest, ":") do
      [request_id, index_str] when request_id != "" ->
        case Integer.parse(index_str) do
          {index, ""} -> {:ok, request_id, index}
          _ -> :ignore
        end

      _ ->
        :ignore
    end
  end

  def parse_callback_data(_), do: :ignore

  # --- Private helpers ---

  defp build_approval_text(request) do
    agent_name =
      request.agent
      |> to_string()
      |> String.replace("Elixir.", "")
      |> String.split(".")
      |> List.last()

    context_section =
      if request.context == %{} do
        ""
      else
        context_str =
          request.context
          |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
          |> Enum.join(", ")

        "\n\n<b>Context:</b> #{context_str}"
      end

    "<b>[#{agent_name}]</b> requests approval:\n\n#{request.description}#{context_section}"
  end

  defp build_callback_data(request_id, index) do
    data = "ag:#{request_id}:#{index}"

    if byte_size(data) > @max_callback_data do
      # Truncate request_id to fit within limit
      # "ag:" (3) + ":" (1) + index digits (max ~2) = 6 bytes overhead
      max_id_len = @max_callback_data - 6
      truncated_id = binary_part(request_id, 0, max_id_len)
      "ag:#{truncated_id}:#{index}"
    else
      data
    end
  end

  defp decision_status_line(_decision, :timeout), do: "⏰ <b>Timed out</b>"
  defp decision_status_line(_decision, :kill_switch), do: "🛑 <b>Kill switch activated</b>"

  defp decision_status_line(decision, decided_by) do
    icon = if String.downcase(to_string(decision)) =~ "reject", do: "❌", else: "✅"
    by_text = if decided_by == :auto_rule, do: "auto-rule", else: to_string(decided_by)
    "#{icon} <b>#{decision}</b> by #{by_text}"
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max - 3) <> "..."
end
