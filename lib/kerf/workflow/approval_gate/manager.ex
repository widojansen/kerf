defmodule Kerf.Workflow.ApprovalGate.Manager do
  @moduledoc """
  GenServer that manages approval request lifecycle.

  Creates, tracks, and resolves pending approval requests.
  Uses ETS for pending request storage and Process.monitor
  for automatic cleanup on agent crash.
  """

  use GenServer

  alias Kerf.Workflow.ApprovalGate.{AutoRule, TelegramRenderer, Log}

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Request approval. Blocks the caller until resolved, timed out, or killed.
  """
  def request_approval(manager, request) do
    timeout = Map.get(request, :timeout_ms, 300_000)
    # Add generous buffer for GenServer overhead
    GenServer.call(manager, {:request_approval, request}, timeout + 5_000)
  end

  @doc """
  Resolve a pending request. Called by CallbackHandler when a button is tapped.
  """
  def resolve(manager, request_id, decision, decided_by) do
    GenServer.call(manager, {:resolve, request_id, decision, decided_by})
  end

  @doc """
  List all pending approval requests.
  """
  def pending(manager) do
    GenServer.call(manager, :pending)
  end

  @doc """
  Kill switch: reject all pending requests and suspend new ones.
  """
  def kill_switch(manager, duration_ms \\ 60_000) do
    GenServer.call(manager, {:kill_switch, duration_ms})
  end

  @doc """
  Resume accepting requests after kill switch.
  """
  def resume(manager) do
    GenServer.call(manager, :resume)
  end

  @doc """
  Revoke a specific pending request.
  """
  def revoke(manager, request_id) do
    GenServer.call(manager, {:revoke, request_id})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    table = :ets.new(:approval_gate_pending, [:set, :public])

    state = %{
      table: table,
      telegram_client: Keyword.get(opts, :telegram_client, &default_telegram_client/3),
      telegram_token: Keyword.get(opts, :telegram_token),
      default_chat_id: Keyword.get(opts, :default_chat_id),
      suspended_until: nil,
      suspend_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request_approval, request}, from, state) do
    # Check suspension
    if suspended?(state) do
      {:reply, {:error, :suspended}, state}
    else
      # Check auto-approval rules
      case AutoRule.match(request) do
        {:ok, rule} ->
          metadata = %{
            decided_by: :auto_rule,
            decision: rule.decision,
            decided_at: DateTime.utc_now(),
            rule_id: rule.id
          }

          log_request_and_decision(request, metadata)

          result =
            if String.downcase(rule.decision) =~ "reject",
              do: {:rejected, metadata},
              else: {:approved, metadata}

          {:reply, result, state}

        :no_match ->
          handle_new_request(request, from, state)
      end
    end
  end

  def handle_call({:resolve, request_id, decision, decided_by}, _from, state) do
    case :ets.lookup(state.table, request_id) do
      [{^request_id, pending}] ->
        do_resolve(request_id, pending, decision, decided_by, state)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:pending, _from, state) do
    pending =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_id, entry} -> entry end)

    {:reply, pending, state}
  end

  def handle_call({:kill_switch, duration_ms}, _from, state) do
    # Reject all pending
    :ets.tab2list(state.table)
    |> Enum.each(fn {request_id, pending} ->
      do_resolve(request_id, pending, "reject", :kill_switch, state)
    end)

    # Set suspension
    if state.suspend_timer, do: Process.cancel_timer(state.suspend_timer)
    timer = Process.send_after(self(), :suspend_expired, duration_ms)

    state = %{state | suspended_until: DateTime.add(DateTime.utc_now(), duration_ms, :millisecond), suspend_timer: timer}
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    if state.suspend_timer, do: Process.cancel_timer(state.suspend_timer)
    {:reply, :ok, %{state | suspended_until: nil, suspend_timer: nil}}
  end

  def handle_call({:revoke, request_id}, _from, state) do
    case :ets.lookup(state.table, request_id) do
      [{^request_id, pending}] ->
        do_cleanup(request_id, pending, state)
        GenServer.reply(pending.from, {:error, :revoked})
        log_decision(request_id, "revoked", :revoked, pending)
        update_telegram_message(pending, "revoked", :revoked, state)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case :ets.lookup(state.table, request_id) do
      [{^request_id, pending}] ->
        do_cleanup(request_id, pending, state)
        GenServer.reply(pending.from, {:error, :timeout})
        log_decision(request_id, "timeout", :timeout, pending)
        update_telegram_message(pending, "timeout", :timeout, state)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Find pending request by monitor ref
    match =
      :ets.tab2list(state.table)
      |> Enum.find(fn {_id, entry} -> entry.monitor_ref == ref end)

    case match do
      {request_id, pending} ->
        Process.cancel_timer(pending.timeout_ref)
        :ets.delete(state.table, request_id)
        log_decision(request_id, "agent_crashed", :agent_crash, pending)

      nil ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(:suspend_expired, state) do
    {:noreply, %{state | suspended_until: nil, suspend_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp handle_new_request(request, from, state) do
    request_id = generate_request_id()
    chat_id = Map.get(request, :chat_id) || state.default_chat_id
    now = DateTime.utc_now()
    timeout_ms = Map.get(request, :timeout_ms, 300_000)

    # Monitor the calling process
    {caller_pid, _} = from
    monitor_ref = Process.monitor(caller_pid)

    # Send Telegram message
    telegram_message_id = send_telegram_approval(request_id, request, chat_id, state)

    # Set timeout
    timeout_ref = Process.send_after(self(), {:timeout, request_id}, timeout_ms)

    pending = %{
      request_id: request_id,
      agent: request.agent,
      agent_pid: caller_pid,
      monitor_ref: monitor_ref,
      from: from,
      action: request.action,
      description: request.description,
      context: request.context,
      options: request.options,
      chat_id: chat_id,
      telegram_message_id: telegram_message_id,
      timeout_ref: timeout_ref,
      requested_at: now,
      timeout_ms: timeout_ms
    }

    :ets.insert(state.table, {request_id, pending})

    # Log the request
    try do
      Log.log_request(%{
        request_id: request_id,
        agent_module: to_string(request.agent),
        action: request.action,
        description: request.description,
        context: request.context,
        chat_id: chat_id,
        requested_at: now,
        timeout_ms: timeout_ms,
        telegram_message_id: telegram_message_id
      })
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end

  defp do_resolve(request_id, pending, decision, decided_by, state) do
    do_cleanup(request_id, pending, state)

    metadata = %{
      decided_by: decided_by,
      decision: decision,
      decided_at: DateTime.utc_now(),
      rule_id: nil
    }

    result =
      if String.downcase(to_string(decision)) =~ "reject" or decided_by == :kill_switch,
        do: {:rejected, metadata},
        else: {:approved, metadata}

    # Kill switch replies with {:error, :killed} instead
    if decided_by == :kill_switch do
      GenServer.reply(pending.from, {:error, :killed})
    else
      GenServer.reply(pending.from, result)
    end

    log_decision(request_id, decision, decided_by, pending)
    update_telegram_message(pending, decision, decided_by, state)
  end

  defp do_cleanup(request_id, pending, state) do
    Process.cancel_timer(pending.timeout_ref)
    Process.demonitor(pending.monitor_ref, [:flush])
    :ets.delete(state.table, request_id)
  end

  defp suspended?(%{suspended_until: nil}), do: false

  defp suspended?(%{suspended_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  defp send_telegram_approval(request_id, request, chat_id, state) do
    pending_for_render = %{
      request_id: request_id,
      agent: request.agent,
      action: request.action,
      description: request.description,
      context: request.context,
      options: request.options,
      chat_id: chat_id,
      requested_at: DateTime.utc_now(),
      timeout_ms: Map.get(request, :timeout_ms, 300_000)
    }

    payload = TelegramRenderer.render_approval_message(pending_for_render)

    try do
      case state.telegram_client.("sendMessage", telegram_url(state, "sendMessage"), payload) do
        {:ok, %{body: %{"ok" => true, "result" => %{"message_id" => msg_id}}}} -> msg_id
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp update_telegram_message(pending, decision, decided_by, state) do
    if pending.telegram_message_id do
      payload = TelegramRenderer.render_decision_message(pending, decision, decided_by)

      try do
        state.telegram_client.("editMessageText", telegram_url(state, "editMessageText"), payload)
      rescue
        _ -> :ok
      end
    end
  end

  defp log_decision(request_id, decision, decided_by, pending) do
    try do
      Log.log_decision(request_id, to_string(decision), decided_by,
        telegram_message_id: pending.telegram_message_id
      )
    rescue
      _ -> :ok
    end
  end

  defp log_request_and_decision(request, metadata) do
    request_id = generate_request_id()

    try do
      Log.log_request(%{
        request_id: request_id,
        agent_module: to_string(request.agent),
        action: request.action,
        description: request.description,
        context: request.context,
        chat_id: Map.get(request, :chat_id),
        requested_at: DateTime.utc_now(),
        timeout_ms: Map.get(request, :timeout_ms, 300_000)
      })

      Log.log_decision(request_id, metadata.decision, metadata.decided_by,
        rule_id: metadata.rule_id
      )
    rescue
      _ -> :ok
    end
  end

  defp telegram_url(state, method) do
    "https://api.telegram.org/bot#{state.telegram_token}/#{method}"
  end

  defp generate_request_id do
    "ag_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp default_telegram_client(_method, url, body) do
    Req.post(url, json: body)
  end
end
