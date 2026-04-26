defmodule Kerf.Memory.Embedder do
  @moduledoc """
  Generates text embeddings via an OpenAI-compatible /v1/embeddings endpoint.

  Designed for Hugging Face TEI (Text Embeddings Inference) but works with
  any OpenAI-compatible embedding service (vLLM --task embed, etc.).

  Uses BAAI/bge-m3 by default (1024-dim vectors, multilingual incl. Dutch).
  Connects to any OpenAI-compatible /v1/embeddings endpoint. Same HTTP client
  injection pattern as the LLM providers for testability.

  ## Configuration

      config :exclaw, Kerf.Memory.Embedder,
        base_url: "http://localhost:11434",
        model: "bge-m3"

  ## Backends

  **Ollama (default, ARM64-compatible):**

      ollama pull bge-m3

  **TEI (x86_64 only — no ARM64 images as of 2026-03):**

      docker run -p 8090:80 ghcr.io/huggingface/text-embeddings-inference:latest \\
        --model-id BAAI/bge-m3
      # Then set EMBEDDING_URL=http://localhost:8090

  **vLLM (GPU-accelerated, for high-throughput batch embedding):**

      vllm serve BAAI/bge-m3 --task embed --port 8001 \\
        --hf-overrides '{"architectures": ["BgeM3EmbeddingModel"]}'
      # Then set EMBEDDING_URL=http://localhost:8001
  """

  use GenServer
  require Logger

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Embed a single text string. Returns {:ok, [float]} | {:error, reason}."
  def embed(name \\ __MODULE__, text) do
    GenServer.call(name, {:embed, text}, 30_000)
  end

  @doc "Embed a batch of texts. Returns {:ok, [[float]]} | {:error, reason}."
  def embed_batch(name \\ __MODULE__, texts) do
    GenServer.call(name, {:embed_batch, texts}, 60_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    config = Application.get_env(:exclaw, __MODULE__, [])

    base_url = Keyword.get(opts, :base_url) || Keyword.get(config, :base_url, "http://localhost:8090")
    model = Keyword.get(opts, :model) || Keyword.get(config, :model, "nomic-embed-text")
    adapter = Keyword.get(opts, :adapter)

    req_opts = [base_url: base_url, headers: [{"content-type", "application/json"}]]
    req_opts = if adapter, do: Keyword.put(req_opts, :adapter, adapter), else: req_opts

    state = %{
      req: Req.new(req_opts),
      model: model
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:embed, text}, _from, state) do
    result = do_embed(text, state)
    {:reply, result, state}
  end

  def handle_call({:embed_batch, texts}, _from, state) do
    result = do_embed_batch(texts, state)
    {:reply, result, state}
  end

  # --- Private ---

  defp do_embed(text, state) when is_binary(text) and byte_size(text) > 0 do
    body = Jason.encode!(%{"model" => state.model, "input" => text})

    case make_request(state.req, body) do
      {:ok, [embedding | _]} -> {:ok, embedding}
      {:ok, []} -> {:error, "no embedding returned"}
      {:error, _} = error -> error
    end
  end

  defp do_embed(_text, _state), do: {:error, "text must be a non-empty string"}

  defp do_embed_batch(texts, state) when is_list(texts) and length(texts) > 0 do
    body = Jason.encode!(%{"model" => state.model, "input" => texts})

    case make_request(state.req, body) do
      {:ok, embeddings} when length(embeddings) == length(texts) -> {:ok, embeddings}
      {:ok, _} -> {:error, "embedding count mismatch"}
      {:error, _} = error -> error
    end
  end

  defp do_embed_batch(_texts, _state), do: {:error, "texts must be a non-empty list"}

  defp make_request(req, body) do
    try do
      case Req.post(req, url: "/v1/embeddings", body: body) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}}
        when is_list(data) ->
          embeddings =
            data
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          {:ok, embeddings}

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, %{"data" => data}} when is_list(data) ->
              embeddings =
                data
                |> Enum.sort_by(& &1["index"])
                |> Enum.map(& &1["embedding"])

              {:ok, embeddings}

            _ ->
              {:error, "malformed response: missing data"}
          end

        {:ok, %Req.Response{status: 200, body: _}} ->
          {:error, "malformed response: missing data"}

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
end
