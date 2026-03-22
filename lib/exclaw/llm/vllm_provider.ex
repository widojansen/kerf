defmodule ExClaw.LLM.VLLMProvider do
  @moduledoc """
  LLM Provider backend for vLLM (and any OpenAI-compatible server).

  Speaks the standard OpenAI /v1/chat/completions format and returns
  the same internal response shape as ExClaw.LLM.Provider so callers
  are backend-agnostic:

      {:ok, %{type: :text, content: string, usage: %{input_tokens: n, output_tokens: n}}}
      {:ok, %{type: :tool_use, calls: [...], usage: ...}}
      {:error, reason}

  Configured via:

      config :exclaw, ExClaw.LLM.VLLMProvider,
        base_url: "http://localhost:8000",
        default_model: "nvidia/Qwen3-32B-NVFP4",
        default_max_tokens: 8192

  Works with vLLM, SGLang, LMDeploy, or any server exposing
  the OpenAI chat completions API.
  """

  use GenServer
  require Logger

  # --- Public API (mirrors ExClaw.LLM.Provider) ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def complete(name \\ __MODULE__, model, messages, opts \\ []) do
    GenServer.call(name, {:complete, model, messages, opts}, 180_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:8000")
    adapter = Keyword.get(opts, :adapter)
    rate_limiter = Keyword.get(opts, :rate_limiter, ExClaw.LLM.RateLimiter)
    api_key = Keyword.get(opts, :api_key, "not-needed")

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]

    req_opts = [base_url: base_url, headers: headers, receive_timeout: 120_000]
    req_opts = if adapter, do: Keyword.put(req_opts, :adapter, adapter), else: req_opts

    state = %{
      req: Req.new(req_opts),
      default_model: Keyword.get(opts, :default_model, "nvidia/Qwen3-32B-NVFP4"),
      default_max_tokens: Keyword.get(opts, :default_max_tokens, 8192),
      rate_limiter: rate_limiter
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:complete, model, messages, opts}, _from, state) do
    result = do_complete(model, messages, opts, state)
    {:reply, result, state}
  end

  # --- Private ---

  defp do_complete(model, messages, opts, state) do
    with :ok <- check_rate_limit(state) do
      body = build_request_body(model, messages, opts, state)
      started_at = System.monotonic_time(:millisecond)

      case make_request(state.req, body) do
        {:ok, response} ->
          duration_ms = System.monotonic_time(:millisecond) - started_at
          record_usage(response, state)
          log_llm_call(model, duration_ms, response)
          {:ok, response}

        {:error, reason} = error ->
          duration_ms = System.monotonic_time(:millisecond) - started_at
          log_llm_error(model, duration_ms, reason)
          error
      end
    end
  end

  defp check_rate_limit(%{rate_limiter: rl}) do
    ExClaw.LLM.RateLimiter.check_budget(rl)
  end

  defp build_request_body(model, messages, opts, state) do
    # OpenAI format: messages list with role/content maps.
    # Prepend system prompt if provided.
    openai_messages =
      case Keyword.get(opts, :system) do
        nil -> normalise_messages(messages)
        system -> [%{role: "system", content: system} | normalise_messages(messages)]
      end

    body = %{
      model: model,
      messages: openai_messages,
      max_tokens: Keyword.get(opts, :max_tokens, state.default_max_tokens),
      stream: false
    }

    # Add tools if provided. Convert from Anthropic format to OpenAI format
    # if needed (Session sends Anthropic-style tool definitions).
    body =
      case Keyword.get(opts, :tools) do
        nil -> body
        tools -> Map.put(body, :tools, Enum.map(tools, &to_openai_tool/1))
      end

    # Add temperature if provided.
    body =
      case Keyword.get(opts, :temperature) do
        nil -> body
        temp -> Map.put(body, :temperature, temp)
      end

    Jason.encode!(body)
  end

  # Convert messages from Anthropic format (used by Session) to OpenAI format.
  # Handles: plain text messages, tool_use assistant messages, tool_result user messages.
  defp normalise_messages(messages) do
    Enum.flat_map(messages, fn msg -> convert_message(msg) end)
  end

  # Plain text message (string content)
  defp convert_message(%{role: role, content: content}) when is_binary(content) do
    [%{role: to_string(role), content: content}]
  end

  defp convert_message(%{"role" => role, "content" => content}) when is_binary(content) do
    [%{role: role, content: content}]
  end

  # Anthropic assistant tool_use message -> OpenAI assistant with tool_calls
  defp convert_message(%{role: "assistant", content: content}) when is_list(content) do
    tool_calls =
      content
      |> Enum.filter(fn item -> is_map(item) and Map.get(item, :type) == "tool_use" end)
      |> Enum.map(fn call ->
        %{
          id: call.id,
          type: "function",
          function: %{
            name: call.name,
            arguments: Jason.encode!(call.input || %{})
          }
        }
      end)

    if tool_calls == [] do
      # Content list without tool_use — extract text
      text = content |> Enum.map_join("
", fn
        %{text: t} -> t
        %{"text" => t} -> t
        _ -> ""
      end)
      [%{role: "assistant", content: text}]
    else
      [%{role: "assistant", content: nil, tool_calls: tool_calls}]
    end
  end

  # Anthropic user tool_result message -> OpenAI tool messages (one per result)
  defp convert_message(%{role: "user", content: content}) when is_list(content) do
    results =
      content
      |> Enum.filter(fn item -> is_map(item) and Map.get(item, :type) == "tool_result" end)

    if results == [] do
      # Regular user message with list content — shouldn't happen but handle gracefully
      [%{role: "user", content: inspect(content)}]
    else
      Enum.map(results, fn result ->
        %{
          role: "tool",
          tool_call_id: result.tool_use_id,
          content: to_string(result.content)
        }
      end)
    end
  end

  # Fallback
  defp convert_message(other), do: [other]

  # Convert Anthropic-style tool definition to OpenAI format.
  # Anthropic: %{"name" => ..., "description" => ..., "input_schema" => ...}
  # OpenAI:    %{"type" => "function", "function" => %{"name" => ..., "description" => ..., "parameters" => ...}}
  defp to_openai_tool(%{"type" => "function", "function" => _} = tool), do: tool
  defp to_openai_tool(%{type: "function", function: _} = tool), do: tool

  defp to_openai_tool(tool) do
    name = Map.get(tool, "name") || Map.get(tool, :name, "")
    desc = Map.get(tool, "description") || Map.get(tool, :description, "")
    schema = Map.get(tool, "input_schema") || Map.get(tool, :input_schema, %{})

    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => schema
      }
    }
  end

  defp make_request(req, body) do
    try do
      case Req.post(req, url: "/v1/chat/completions", body: body) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          parse_response(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, decoded} -> parse_response(decoded)
            {:error, _} -> {:error, "malformed response: invalid JSON"}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          reason = if is_binary(body), do: body, else: inspect(body)
          {:error, "API error #{status}: #{reason}"}

        {:error, exception} ->
          {:error, "request failed: #{Exception.message(exception)}"}
      end
    rescue
      e -> {:error, "request failed: #{Exception.message(e)}"}
    end
  end

  # Parse OpenAI chat completion response.
  defp parse_response(%{"choices" => [choice | _], "usage" => usage}) do
    message = Map.get(choice, "message", %{})
    input_tokens = Map.get(usage, "prompt_tokens", 0)
    output_tokens = Map.get(usage, "completion_tokens", 0)

    usage_map = %{input_tokens: input_tokens, output_tokens: output_tokens}

    case Map.get(message, "tool_calls") do
      nil ->
        {:ok,
         %{
           type: :text,
           content: Map.get(message, "content", ""),
           usage: usage_map
         }}

      [] ->
        {:ok,
         %{
           type: :text,
           content: Map.get(message, "content", ""),
           usage: usage_map
         }}

      tool_calls when is_list(tool_calls) ->
        calls =
          Enum.map(tool_calls, fn tc ->
            func = Map.get(tc, "function", %{})
            args_str = Map.get(func, "arguments", "{}")

            args =
              case Jason.decode(args_str) do
                {:ok, parsed} -> parsed
                {:error, _} -> %{}
              end

            %{
              id: Map.get(tc, "id"),
              name: Map.get(func, "name"),
              input: args
            }
          end)

        {:ok, %{type: :tool_use, calls: calls, usage: usage_map}}
    end
  end

  defp parse_response(_body) do
    {:error, "malformed response: missing choices or usage"}
  end

  defp record_usage(%{usage: usage}, %{rate_limiter: rl}) do
    total = (usage.input_tokens || 0) + (usage.output_tokens || 0)
    ExClaw.LLM.RateLimiter.record_usage(rl, total)
  end

  defp record_usage(_, _), do: :ok

  defp log_llm_call(model, duration_ms, response) do
    try do
      usage = Map.get(response, :usage, %{})

      ExClaw.Dashboard.EventLog.log(:llm_call, %{
        model: model,
        duration_ms: duration_ms,
        input_tokens: Map.get(usage, :input_tokens),
        output_tokens: Map.get(usage, :output_tokens),
        response_type: response.type,
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    end
  end

  defp log_llm_error(model, duration_ms, reason) do
    try do
      ExClaw.Dashboard.EventLog.log(:llm_error, %{
        model: model,
        duration_ms: duration_ms,
        error: inspect(reason),
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    end
  end
end
