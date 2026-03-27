defmodule ExClaw.Memory.Embedder do
  @moduledoc """
  Generates text embeddings via Ollama's /api/embed endpoint.

  Uses nomic-embed-text by default (768-dim vectors). Same HTTP client
  injection pattern as the LLM providers for testability.

  ## Configuration

      config :exclaw, ExClaw.Memory.Embedder,
        base_url: "http://localhost:11434",
        model: "nomic-embed-text"
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

    base_url = Keyword.get(opts, :base_url) || Keyword.get(config, :base_url, "http://localhost:11434")
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
      case Req.post(req, url: "/api/embed", body: body) do
        {:ok, %Req.Response{status: 200, body: %{"embeddings" => embeddings}}}
        when is_list(embeddings) ->
          {:ok, embeddings}

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, %{"embeddings" => embeddings}} when is_list(embeddings) ->
              {:ok, embeddings}

            _ ->
              {:error, "malformed response: missing embeddings"}
          end

        {:ok, %Req.Response{status: 200, body: _}} ->
          {:error, "malformed response: missing embeddings"}

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
