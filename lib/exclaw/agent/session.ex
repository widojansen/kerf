defmodule ExClaw.Agent.Session do
  @moduledoc """
  GenServer per chat group — the core agent loop.
  Receives user messages, calls the LLM, executes tools, and loops
  until a text response is produced.
  """
  use GenServer, restart: :temporary

  require Logger

  alias ExClaw.LLM.Provider
  alias ExClaw.Security.{FileGuard, ShellSandbox, PromptGuard}

  @default_max_iterations 25
  @default_idle_timeout 1_800_000

  # --- Public API ---

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def send_message(pid, message) do
    GenServer.call(pid, {:message, message}, 180_000)
  end

  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    state = %{
      group_id: Keyword.fetch!(opts, :group_id),
      model: Keyword.fetch!(opts, :model),
      messages: [],
      tools: Keyword.get(opts, :tools, []),
      tool_executor: Keyword.get(opts, :tool_executor, &default_tool_executor/2),
      provider: Keyword.fetch!(opts, :provider),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
      started_at: now,
      last_activity: now,
      session_id: "#{Keyword.fetch!(opts, :group_id)}_#{System.unique_integer([:positive])}"
    }

    emit_telemetry(:session_lifecycle, state, %{event: "started"})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      group_id: state.group_id,
      message_count: length(state.messages),
      model: state.model,
      started_at: state.started_at,
      last_activity: state.last_activity
    }

    {:reply, info, state, idle_timeout(state)}
  end

  @impl true
  def handle_call({:message, message}, _from, state) do
    started_at = System.monotonic_time(:millisecond)
    state = %{state | last_activity: DateTime.utc_now() |> DateTime.truncate(:second)}
    state = append_user_message(state, message)

    case agent_loop(state, 0) do
      {:ok, text, state} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        emit_telemetry(:message_round_trip, state, %{
          duration_ms: duration_ms,
          message_count: length(state.messages),
          response_type: "text"
        })

        {:reply, {:ok, text}, state, idle_timeout(state)}

      {:error, reason, state} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        emit_telemetry(:message_round_trip, state, %{
          duration_ms: duration_ms,
          message_count: length(state.messages),
          response_type: "error",
          error_message: inspect(reason)
        })

        {:reply, {:error, reason}, state, idle_timeout(state)}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state, :hibernate}
  end

  # --- Private ---

  defp agent_loop(state, iteration) when iteration >= state.max_iterations do
    {:error, "max iteration limit reached (#{state.max_iterations})", state}
  end

  defp agent_loop(state, iteration) do
    opts = build_provider_opts(state)

    case Provider.complete(state.provider, state.model, state.messages, opts) do
      {:ok, %{type: :text, content: text}} ->
        state = append_assistant_text(state, text)
        {:ok, text, state}

      {:ok, %{type: :tool_use, calls: calls}} ->
        state = append_assistant_tool_use(state, calls)
        results = execute_tool_calls(calls, state)
        state = append_tool_results(state, results)
        agent_loop(state, iteration + 1)

      {:error, reason} ->
        {:error, reason, state}

      {:denied, reason} ->
        {:error, reason, state}
    end
  end

  defp execute_tool_calls(calls, state) do
    Enum.map(calls, fn call ->
      result = execute_single_tool(call, state)
      %{tool_use_id: call.id, content: result}
    end)
  end

  defp execute_single_tool(call, state) do
    started_at = System.monotonic_time(:millisecond)

    # Anthropic returns string-keyed maps; security modules expect atom keys.
    # If atomization fails (unknown keys), deny security-sensitive tools rather
    # than silently passing unchecked string-keyed maps to security guards.
    result =
      case atomize_keys(call.input) do
        {:ok, atom_input} ->
          with :ok <- FileGuard.check(call.name, atom_input),
               :ok <- ShellSandbox.check(call.name, atom_input),
               :ok <- PromptGuard.check(call.input) do
            run_tool_executor(call, state)
          else
            {:denied, reason} -> "Security denied: #{reason}"
          end

        :atomize_failed ->
          "Security denied: unrecognized tool input keys"
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at
    security_result = if String.starts_with?(result, "Security denied:"), do: "denied", else: "ok"

    emit_telemetry(:tool_execution, state, %{
      tool_name: call.name,
      duration_ms: duration_ms,
      security_result: security_result,
      output_data: String.slice(result, 0, 200)
    })

    result
  end

  defp run_tool_executor(call, state) do
    try do
      case state.tool_executor.(call.name, call.input) do
        {:ok, result} -> to_string(result)
        {:error, reason} -> "Tool error: #{reason}"
      end
    rescue
      e -> "Tool error: #{Exception.message(e)}"
    end
  end

  defp build_provider_opts(state) do
    opts = []
    opts = if state.tools != [], do: Keyword.put(opts, :tools, state.tools), else: opts
    opts = if state.system_prompt, do: Keyword.put(opts, :system, state.system_prompt), else: opts
    opts
  end

  defp append_user_message(state, text) do
    message = %{role: "user", content: text}
    %{state | messages: state.messages ++ [message]}
  end

  defp append_assistant_text(state, text) do
    message = %{role: "assistant", content: text}
    %{state | messages: state.messages ++ [message]}
  end

  defp append_assistant_tool_use(state, calls) do
    content =
      Enum.map(calls, fn call ->
        %{type: "tool_use", id: call.id, name: call.name, input: call.input}
      end)

    message = %{role: "assistant", content: content}
    %{state | messages: state.messages ++ [message]}
  end

  defp append_tool_results(state, results) do
    content =
      Enum.map(results, fn result ->
        %{type: "tool_result", tool_use_id: result.tool_use_id, content: result.content}
      end)

    message = %{role: "user", content: content}
    %{state | messages: state.messages ++ [message]}
  end

  defp idle_timeout(%{idle_timeout: :infinity}), do: :hibernate
  defp idle_timeout(%{idle_timeout: ms}), do: ms

  defp default_tool_executor(_name, _input) do
    {:error, "tool not available"}
  end

  defp atomize_keys(map) when is_map(map) do
    {:ok,
     Map.new(map, fn
       {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
       {k, v} -> {k, v}
     end)}
  rescue
    ArgumentError -> :atomize_failed
  end

  defp emit_telemetry(category, state, data) do
    try do
      ExClaw.Telemetry.emit(category, Map.merge(data, %{
        group_id: state.group_id,
        session_id: state.session_id,
        model: state.model
      }))
    rescue
      _ -> :ok
    end
  end
end
