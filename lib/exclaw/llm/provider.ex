defmodule ExClaw.LLM.Provider do
  @moduledoc """
  GenServer wrapping Req for the Anthropic Messages API.
  Handles completion requests with rate limiting and error handling.
  """
  use GenServer

  require Logger

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def complete(name \\ __MODULE__, model, messages, opts \\ []) do
    GenServer.call(name, {:complete, model, messages, opts}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    api_key = resolve_api_key(Keyword.get(opts, :api_key))
    base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com/v1")
    anthropic_version = Keyword.get(opts, :anthropic_version, "2023-06-01")
    adapter = Keyword.get(opts, :adapter)
    rate_limiter = Keyword.get(opts, :rate_limiter, ExClaw.LLM.RateLimiter)

    req =
      if api_key do
        req_opts = [
          base_url: base_url,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", anthropic_version},
            {"content-type", "application/json"}
          ]
        ]

        req_opts = if adapter, do: Keyword.put(req_opts, :adapter, adapter), else: req_opts
        Req.new(req_opts)
      else
        nil
      end

    state = %{
      req: req,
      default_model: Keyword.get(opts, :default_model, "claude-sonnet-4-20250514"),
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

  defp do_complete(_model, _messages, _opts, %{req: nil}) do
    {:error, "API key not configured"}
  end

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
    body = %{
      model: model,
      max_tokens: Keyword.get(opts, :max_tokens, state.default_max_tokens),
      messages: messages
    }

    body = if tools = Keyword.get(opts, :tools), do: Map.put(body, :tools, tools), else: body
    body = if system = Keyword.get(opts, :system), do: Map.put(body, :system, system), else: body

    Jason.encode!(body)
  end

  defp make_request(req, body) do
    case Req.post(req, url: "/messages", body: body) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        parse_response(body)

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> parse_response(decoded)
          {:error, _} -> {:error, "malformed response: invalid JSON"}
        end

      {:ok, %Req.Response{status: status, body: body}} when is_map(body) ->
        message = get_in(body, ["error", "message"]) || "unknown error"
        {:error, "API error #{status}: #{message}"}

      {:ok, %Req.Response{status: status, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            message = get_in(decoded, ["error", "message"]) || "unknown error"
            {:error, "API error #{status}: #{message}"}

          {:error, _} ->
            {:error, "API error #{status}: #{body}"}
        end

      {:error, exception} ->
        {:error, "request failed: #{Exception.message(exception)}"}
    end
  end

  defp parse_response(%{"content" => content, "usage" => usage}) do
    result = parse_content_blocks(content)
    result = Map.put(result, :usage, %{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"]
    })

    {:ok, result}
  end

  defp parse_response(_body) do
    {:error, "malformed response: missing content or usage"}
  end

  defp parse_content_blocks(blocks) do
    tool_calls =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{id: block["id"], name: block["name"], input: block["input"]}
      end)

    if tool_calls != [] do
      %{type: :tool_use, calls: tool_calls}
    else
      text =
        blocks
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join(&(&1["text"]))

      %{type: :text, content: text}
    end
  end

  defp record_usage(%{usage: usage}, %{rate_limiter: rl}) do
    total = (usage.input_tokens || 0) + (usage.output_tokens || 0)
    ExClaw.LLM.RateLimiter.record_usage(rl, total)
  end

  defp record_usage(_, _), do: :ok

  defp log_llm_call(model, duration_ms, response) do
    try do
      usage = Map.get(response, :usage, %{})
      mem = process_memory()

      event = %{
        model: model,
        duration_ms: duration_ms,
        input_tokens: Map.get(usage, :input_tokens),
        output_tokens: Map.get(usage, :output_tokens),
        response_type: response.type,
        timestamp: DateTime.utc_now()
      }

      ExClaw.Dashboard.EventLog.log(:llm_call, event)
      ExClaw.Telemetry.emit(:llm_call, Map.put(event, :process_memory_bytes, mem))
    rescue
      _ -> :ok
    end
  end

  defp log_llm_error(model, duration_ms, reason) do
    try do
      event = %{
        model: model,
        duration_ms: duration_ms,
        error: inspect(reason),
        timestamp: DateTime.utc_now()
      }

      ExClaw.Dashboard.EventLog.log(:llm_error, event)
      ExClaw.Telemetry.emit(:llm_error, %{
        model: model,
        duration_ms: duration_ms,
        error_type: "llm_error",
        error_message: inspect(reason)
      })
    rescue
      _ -> :ok
    end
  end

  defp process_memory do
    {:memory, bytes} = Process.info(self(), :memory)
    bytes
  end

  defp resolve_api_key({:system, env_var}), do: System.get_env(env_var)
  defp resolve_api_key(nil), do: nil
  defp resolve_api_key(key) when is_binary(key), do: key
end
