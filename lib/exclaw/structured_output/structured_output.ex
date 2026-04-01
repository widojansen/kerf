defmodule ExClaw.StructuredOutput do
  @moduledoc """
  High-level API for getting structured LLM responses.

  Handles provider selection, guided decoding, parsing, validation,
  and retry with error feedback.
  """

  alias ExClaw.StructuredOutput.{JSONParser, SchemaRegistry, Validator}

  @default_max_retries 2
  @default_temperature 0.1

  @doc """
  Get a structured response using a registered schema name.

  Options:
    - `:system` — system prompt
    - `:max_retries` — number of retries on failure (default: 2)
    - `:provider_fn` — `fn(model, messages, opts) -> {:ok, response} | {:error, reason}`
    - `:provider_type` — `:vllm | :anthropic | :ollama` (default: auto-detect from model)
    - `:temperature` — temperature override (default: 0.1)
    - `:max_tokens` — max tokens override (default: from schema or 2048)
    - `:registry` — SchemaRegistry name (default: SchemaRegistry module name)
  """
  @spec complete(atom(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(schema_name, model, messages, opts \\ []) do
    registry = Keyword.get(opts, :registry, SchemaRegistry)

    case SchemaRegistry.get(registry, schema_name) do
      {:ok, schema_def} ->
        do_complete(schema_def, model, messages, opts)

      {:error, :not_found} ->
        {:error, :schema_not_found}
    end
  end

  @doc """
  Get a structured response using an inline schema (no registration needed).
  """
  @spec complete_with_schema(map(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_with_schema(schema_def, model, messages, opts \\ []) do
    do_complete(schema_def, model, messages, opts)
  end

  # --- Core implementation ---

  defp do_complete(schema_def, model, messages, opts) do
    max_retries = Keyword.get(opts, :max_retries, config(:default_max_retries, @default_max_retries))
    temperature = Keyword.get(opts, :temperature, config(:default_temperature, @default_temperature))
    max_tokens = Keyword.get(opts, :max_tokens, Map.get(schema_def, :max_tokens, 2048))
    provider_fn = Keyword.fetch!(opts, :provider_fn)
    provider_type = Keyword.get(opts, :provider_type, detect_provider(model))

    provider_opts =
      build_provider_opts(schema_def, provider_type, opts, temperature, max_tokens)

    attempt(provider_fn, model, messages, provider_opts, schema_def, 0, max_retries, nil)
  end

  defp attempt(provider_fn, model, messages, base_opts, schema_def, attempt_num, max_retries, last_error) do
    if attempt_num > max_retries do
      {:error, {:validation_failed, last_error}}
    else
      # On retry, inject error feedback into messages
      messages =
        if attempt_num > 0 and last_error != nil do
          feedback = format_error_feedback(last_error)
          messages ++ [%{role: "user", content: feedback}]
        else
          messages
        end

      case provider_fn.(model, messages, base_opts) do
        {:ok, %{type: :text, content: content}} ->
          process_response(content, schema_def, provider_fn, model, messages, base_opts, attempt_num, max_retries)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp process_response(content, schema_def, provider_fn, model, messages, base_opts, attempt_num, max_retries) do
    json_schema = schema_def.json_schema
    coercions = Map.get(schema_def, :coercions, [])

    with {:ok, data} <- JSONParser.parse(content),
         {:ok, coerced} <- Validator.coerce(data, coercions),
         :ok <- Validator.validate(coerced, json_schema) do
      {:ok, coerced}
    else
      {:error, reason} ->
        attempt(provider_fn, model, messages, base_opts, schema_def, attempt_num + 1, max_retries, reason)
    end
  end

  # --- Provider opts builders ---

  defp build_provider_opts(schema_def, :vllm, opts, temperature, max_tokens) do
    system = build_system_prompt(schema_def, Keyword.get(opts, :system))

    [
      system: system,
      temperature: temperature,
      max_tokens: max_tokens,
      guided_json: schema_def.json_schema
    ]
  end

  defp build_provider_opts(schema_def, _provider_type, opts, temperature, max_tokens) do
    user_system = Keyword.get(opts, :system, "")
    json_instructions = json_schema_instructions(schema_def)
    system = String.trim("#{user_system}\n\n#{json_instructions}")

    [
      system: system,
      temperature: temperature,
      max_tokens: max_tokens
    ]
  end

  defp build_system_prompt(schema_def, nil) do
    desc = Map.get(schema_def, :description, "")
    "Respond with valid JSON matching the schema. #{desc}"
  end

  defp build_system_prompt(schema_def, user_system) do
    desc = Map.get(schema_def, :description, "")
    "#{user_system}\n\nRespond with valid JSON matching the schema. #{desc}"
  end

  defp json_schema_instructions(schema_def) do
    schema_json = Jason.encode!(schema_def.json_schema, pretty: true)
    desc = Map.get(schema_def, :description, "")

    """
    IMPORTANT: You MUST respond with valid JSON matching this schema exactly. #{desc}

    JSON Schema:
    ```json
    #{schema_json}
    ```

    Respond ONLY with the JSON object, no additional text.
    """
  end

  # --- Provider detection ---

  defp detect_provider(model) do
    cond do
      String.starts_with?(model, "claude") -> :anthropic
      String.starts_with?(model, "nvidia/") -> :vllm
      String.contains?(model, "/") -> :vllm
      true -> :anthropic
    end
  end

  # --- Error formatting ---

  defp format_error_feedback(errors) when is_list(errors) do
    error_text =
      errors
      |> Enum.map(fn
        %{path: path, message: msg} -> "- #{path}: #{msg}"
        other -> "- #{inspect(other)}"
      end)
      |> Enum.join("\n")

    "Your previous response had validation errors. Please fix them and try again:\n#{error_text}\n\nRespond with valid JSON only."
  end

  defp format_error_feedback(error) when is_binary(error) do
    "Your previous response could not be parsed as JSON: #{error}\n\nRespond with valid JSON only."
  end

  defp format_error_feedback(error) do
    "Your previous response was invalid: #{inspect(error)}\n\nRespond with valid JSON only."
  end

  # --- Config ---

  defp config(key, default) do
    Application.get_env(:exclaw, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
