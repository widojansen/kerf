defmodule Kerf.LLM.OllamaProvider do
  @moduledoc """
  LLM Provider backend for Ollama.

  Speaks Ollama's /api/chat format and returns the same internal
  response shape as Kerf.LLM.Provider so callers are backend-agnostic:

      {:ok, %{type: :text, content: string, usage: %{input_tokens: n, output_tokens: n}}}
      {:ok, %{type: :tool_use, calls: [...], usage: ...}}
      {:error, reason}

  Configured via:

      config :exclaw, Kerf.LLM.OllamaProvider,
        base_url: "http://localhost:11434",
        default_model: "qwen3:8b",
        default_max_tokens: 8192
  """

  use GenServer
  require Logger

  # --- Public API (mirrors Kerf.LLM.Provider) ---

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
    base_url = Keyword.get(opts, :base_url, "http://localhost:11434")
    adapter = Keyword.get(opts, :adapter)
    rate_limiter = Keyword.get(opts, :rate_limiter, Kerf.LLM.RateLimiter)

    req_opts = [base_url: base_url, headers: [{"content-type", "application/json"}]]
    req_opts = if adapter, do: Keyword.put(req_opts, :adapter, adapter), else: req_opts

    state = %{
      req: Req.new(req_opts),
      default_model: Keyword.get(opts, :default_model, "qwen3:8b"),
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
    Kerf.LLM.RateLimiter.check_budget(rl)
  end

  defp build_request_body(model, messages, opts, state) do
    # Ollama expects messages as list of %{role, content} maps.
    # Prepend system prompt as a system-role message if provided.
    ollama_messages =
      case Keyword.get(opts, :system) do
        nil -> normalise_messages(messages)
        system -> [%{role: "system", content: system} | normalise_messages(messages)]
      end

    body = %{
      model: model,
      messages: ollama_messages,
      stream: false,
      options: %{
        num_predict: Keyword.get(opts, :max_tokens, state.default_max_tokens)
      }
    }

    Jason.encode!(body)
  end

  # Accept both atom-keyed maps and tuple-style legacy format.
  defp normalise_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{role: to_string(role), content: content}
      %{"role" => role, "content" => content} -> %{role: role, content: content}
      {"role", role, "content", content} -> %{role: role, content: content}
      other -> other
    end)
  end

  defp make_request(req, body) do
    try do
      case Req.post(req, url: "/api/chat", body: body) do
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

  defp parse_response(%{"message" => %{"content" => content}} = body) do
    input_tokens = Map.get(body, "prompt_eval_count", 0)
    output_tokens = Map.get(body, "eval_count", 0)

    result = %{
      type: :text,
      content: content,
      usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
    }

    {:ok, result}
  end

  defp parse_response(_body) do
    {:error, "malformed response: missing message.content"}
  end

  defp record_usage(%{usage: usage}, %{rate_limiter: rl}) do
    total = (usage.input_tokens || 0) + (usage.output_tokens || 0)
    Kerf.LLM.RateLimiter.record_usage(rl, total)
  end

  defp record_usage(_, _), do: :ok

  defp log_llm_call(model, duration_ms, response) do
    try do
      usage = Map.get(response, :usage, %{})
      Kerf.Dashboard.EventLog.log(:llm_call, %{
        model: model,
        duration_ms: duration_ms,
        input_tokens: Map.get(usage, :input_tokens),
        output_tokens: Map.get(usage, :output_tokens),
        response_type: response.type,
        timestamp: DateTime.utc_now()
      })

      Kerf.LLM.Instrumentation.emit_call_stop(:ollama, model, duration_ms, response)
    rescue
      _ -> :ok
    end
  end

  defp log_llm_error(model, duration_ms, reason) do
    try do
      Kerf.Dashboard.EventLog.log(:llm_error, %{
        model: model,
        duration_ms: duration_ms,
        error: inspect(reason),
        timestamp: DateTime.utc_now()
      })

      Kerf.LLM.Instrumentation.emit_call_error(:ollama, model, duration_ms, reason)
    rescue
      _ -> :ok
    end
  end
end
