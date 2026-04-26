defmodule Kerf.Workflow.ApprovalGate.CallbackHandler do
  @moduledoc """
  GenServer that receives Telegram callback query updates
  and routes them to the Manager for resolution.
  """

  use GenServer

  alias Kerf.Workflow.ApprovalGate.TelegramRenderer

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Handle a Telegram callback query. Parses the callback_data,
  resolves the approval request, and sends answerCallbackQuery.
  """
  def handle_callback(handler, callback_query) do
    GenServer.call(handler, {:handle_callback, callback_query})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %{
      manager: Keyword.fetch!(opts, :manager),
      telegram_client: Keyword.get(opts, :telegram_client, &default_telegram_client/3),
      telegram_token: Keyword.get(opts, :telegram_token)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:handle_callback, callback_query}, _from, state) do
    callback_data = callback_query["data"] || ""
    callback_query_id = callback_query["id"]

    case TelegramRenderer.parse_callback_data(callback_data) do
      {:ok, request_id, option_index} ->
        # Look up the pending request to get the option label
        pending = Kerf.Workflow.ApprovalGate.Manager.pending(state.manager)

        case Enum.find(pending, &(&1.request_id == request_id)) do
          nil ->
            # Already resolved or timed out — answer the callback to dismiss spinner
            answer_callback(callback_query_id, "Already handled", state)

          entry ->
            decision = Enum.at(entry.options, option_index, "unknown")

            Kerf.Workflow.ApprovalGate.Manager.resolve(
              state.manager,
              request_id,
              decision,
              :human
            )

            answer_callback(callback_query_id, decision, state)
        end

      :ignore ->
        :ok
    end

    {:reply, :ok, state}
  end

  # --- Private ---

  defp answer_callback(callback_query_id, decision, state) when is_binary(callback_query_id) do
    payload = TelegramRenderer.render_callback_answer(callback_query_id, decision)

    try do
      url = "https://api.telegram.org/bot#{state.telegram_token}/answerCallbackQuery"
      state.telegram_client.("answerCallbackQuery", url, payload)
    rescue
      _ -> :ok
    end
  end

  defp answer_callback(_, _, _), do: :ok

  defp default_telegram_client(_method, url, body) do
    Req.post(url, json: body)
  end
end
