defmodule ExClaw.Channels.Telegram do
  @moduledoc """
  Telegram Bot channel for ExClaw using long polling.

  Polls the Telegram Bot API for updates, routes messages through
  Agent.Session, and sends responses back. Only processes messages
  from authorized user IDs (configurable allow list).

  Configured via:

      config :exclaw, ExClaw.Channels.Telegram,
        enabled: true,
        token: "bot123:ABC...",
        allow_from: [12345, 67890],
        poll_interval: 1_000,
        poll_timeout: 30

  Set `allow_from: []` to allow all users (not recommended in production).
  """

  use GenServer
  require Logger

  alias ExClaw.Agent.Supervisor, as: AgentSupervisor
  alias ExClaw.Memory.Store
  alias ExClaw.Tools.Dispatcher

  @telegram_api "https://api.telegram.org"
  @max_message_length 4096

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the bot's current status and config."
  def status(name \\ __MODULE__) do
    GenServer.call(name, :status)
  end

  # --- Pure functions (testable without GenServer) ---

  @doc "Derive an ExClaw group_id from a Telegram update."
  def derive_group_id(%{"message" => %{"chat" => %{"id" => chat_id}}}) do
    "tg_#{chat_id}"
  end

  @doc """
  Extract message details from a Telegram update.
  Returns {:ok, msg} or {:skip, reason}.
  """
  def extract_message(%{"update_id" => update_id, "message" => msg}) when is_map(msg) do
    case msg do
      %{"text" => text, "chat" => %{"id" => chat_id}, "from" => %{"id" => from_id}} ->
        {:ok, %{
          text: text,
          chat_id: chat_id,
          from_id: from_id,
          update_id: update_id,
          first_name: get_in(msg, ["from", "first_name"]) || ""
        }}

      %{"chat" => %{"id" => _}} ->
        {:skip, "no text content"}

      _ ->
        {:skip, "malformed message"}
    end
  end

  def extract_message(%{"update_id" => _}) do
    {:skip, "not a message update"}
  end

  def extract_message(_), do: {:skip, "malformed update"}

  @doc "Check if a user ID is authorized."
  def authorized?(_user_id, []), do: true
  def authorized?(user_id, allow_from), do: user_id in allow_from

  @doc "Strip <think>...</think> tags from model responses."
  def strip_thinking(text) do
    text
    |> String.replace(~r/<think>[\s\S]*?<\/think>\s*/m, "")
    |> String.trim()
  end

  @doc "Build a sendMessage request body."
  def build_send_body(chat_id, text) do
    truncated =
      if String.length(text) > @max_message_length do
        String.slice(text, 0, @max_message_length - 3) <> "..."
      else
        text
      end

    %{"chat_id" => chat_id, "text" => truncated}
  end

  @doc "Parse a getUpdates API response body."
  def parse_updates_response(%{"ok" => true, "result" => updates}) when is_list(updates) do
    {:ok, updates}
  end

  def parse_updates_response(%{"ok" => false, "description" => desc}) do
    {:error, "Telegram API error: #{desc}"}
  end

  def parse_updates_response(_), do: {:error, "malformed Telegram response"}

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    allow_from = Keyword.get(opts, :allow_from, [])
    poll_interval = Keyword.get(opts, :poll_interval, 1_000)
    poll_timeout = Keyword.get(opts, :poll_timeout, 30)
    http_client = Keyword.get(opts, :http_client)

    state = %{
      token: token,
      allow_from: allow_from,
      poll_interval: poll_interval,
      poll_timeout: poll_timeout,
      offset: 0,
      http_client: http_client,
      error_count: 0
    }

    Logger.info("[Telegram] Bot starting, allow_from: #{inspect(allow_from)}")
    schedule_poll(0)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      offset: state.offset,
      allow_from: state.allow_from,
      error_count: state.error_count
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case fetch_updates(state) do
      {:ok, updates} ->
        state = process_updates(updates, state)
        schedule_poll(state.poll_interval)
        {:noreply, %{state | error_count: 0}}

      {:error, reason} ->
        Logger.warning("[Telegram] Poll error: #{inspect(reason)}")
        backoff = min(state.poll_interval * (state.error_count + 2), 30_000)
        schedule_poll(backoff)
        {:noreply, %{state | error_count: state.error_count + 1}}
    end
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Swallow Task.async results
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Swallow Task monitor DOWN messages
    {:noreply, state}
  end

  # --- Private ---

  defp fetch_updates(state) do
    url = "#{@telegram_api}/bot#{state.token}/getUpdates"

    params = %{
      offset: state.offset,
      timeout: state.poll_timeout,
      allowed_updates: Jason.encode!(["message"])
    }

    req = build_req(state)

    case Req.get(req, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        parse_updates_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, "request failed: #{Exception.message(exception)}"}
    end
  rescue
    e -> {:error, "request failed: #{Exception.message(e)}"}
  end

  defp process_updates([], state), do: state

  defp process_updates(updates, state) do
    Enum.reduce(updates, state, fn update, acc ->
      case extract_message(update) do
        {:ok, msg} ->
          if authorized?(msg.from_id, acc.allow_from) do
            handle_authorized_message(msg, acc)
          else
            Logger.debug("[Telegram] Unauthorized user: #{msg.from_id}")
          end

          new_offset = max(acc.offset, msg.update_id + 1)
          %{acc | offset: new_offset}

        {:skip, _reason} ->
          update_id = Map.get(update, "update_id", acc.offset)
          %{acc | offset: max(acc.offset, update_id + 1)}
      end
    end)
  end

  defp handle_authorized_message(msg, state) do
    # Fire-and-forget — process in a Task so polling continues
    token = state.token
    http_client = state.http_client

    Task.Supervisor.async_nolink(
      ExClaw.TaskSupervisor,
      fn ->
        group_id = "tg_#{msg.chat_id}"
        Logger.info("[Telegram] #{msg.first_name} (#{msg.from_id}): #{String.slice(msg.text, 0..60)}")

        session_opts = build_session_opts(group_id)

        case AgentSupervisor.handle_message(
               ExClaw.Agent.Supervisor,
               ExClaw.SessionRegistry,
               group_id,
               msg.text,
               session_opts
             ) do
          {:ok, text} ->
            clean_text = strip_thinking(text)
            send_telegram_message(token, msg.chat_id, clean_text, http_client)
            persist_exchange(group_id, msg.text, clean_text)

          {:error, reason} ->
            Logger.error("[Telegram] Agent error: #{inspect(reason)}")
            send_telegram_message(token, msg.chat_id, "[Error] #{inspect(reason)}", http_client)
        end
      end
    )
  end

  defp build_session_opts(group_id) do
    model = Application.get_env(:exclaw, __MODULE__, [])[:model] ||
            Application.get_env(:exclaw, ExClaw.Channels.CLI, [])[:model] ||
            "claude-sonnet-4-20250514"

    container_manager = ExClaw.Container.Manager
    workspaces_dir =
      Application.get_env(:exclaw, ExClaw.Container.Manager, [])[:workspaces_dir] || "priv/workspaces"

    tool_executor =
      Dispatcher.build_executor(
        container_manager: container_manager,
        group_id: group_id,
        workspaces_dir: workspaces_dir
      )

    tools = Dispatcher.tool_definitions()

    [provider: ExClaw.LLM.ModelRouter, model: model, tool_executor: tool_executor, tools: tools]
  end

  defp send_telegram_message(token, chat_id, text, http_client) do
    url = "#{@telegram_api}/bot#{token}/sendMessage"
    body = build_send_body(chat_id, text)
    req = if http_client, do: Req.new(adapter: http_client), else: Req.new()

    case Req.post(req, url: url, json: body) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[Telegram] sendMessage failed: HTTP #{status}: #{inspect(body)}")
        {:error, "send failed: #{status}"}

      {:error, exception} ->
        Logger.warning("[Telegram] sendMessage error: #{Exception.message(exception)}")
        {:error, Exception.message(exception)}
    end
  rescue
    e ->
      Logger.warning("[Telegram] sendMessage error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp persist_exchange(group_id, user_msg, assistant_msg) do
    try do
      Store.save_message(ExClaw.Memory.Store, group_id, "user", user_msg)
      Store.save_message(ExClaw.Memory.Store, group_id, "assistant", assistant_msg)
    rescue
      _ -> :ok
    end
  end

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end

  defp build_req(%{http_client: nil}), do: Req.new(receive_timeout: 60_000)
  defp build_req(%{http_client: adapter}), do: Req.new(adapter: adapter, receive_timeout: 60_000)
end
