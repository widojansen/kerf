defmodule Kerf.KnowledgeBase.Embedder do
  @moduledoc """
  Generates embeddings via vLLM or Ollama's OpenAI-compatible endpoint.
  Calls POST /v1/embeddings with {"model": ..., "input": [...]}.
  """

  @doc """
  Generate embedding for a single text.
  """
  def embed(text, opts \\ []) do
    text = if is_binary(text), do: String.trim(text), else: ""

    if text == "" do
      {:error, "text cannot be empty"}
    else
      case do_embed([text], opts) do
        {:ok, [embedding]} -> {:ok, embedding}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Generate embeddings for a batch of texts.
  """
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    if texts == [] do
      {:error, "texts cannot be empty"}
    else
      do_embed(texts, opts)
    end
  end

  defp do_embed(texts, opts) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    url = Keyword.get_lazy(opts, :url, fn -> config(:url, "http://localhost:8001") end)
    model = Keyword.get_lazy(opts, :model, fn -> config(:model, "nomic-ai/nomic-embed-text-v1") end)

    body = Jason.encode!(%{"model" => model, "input" => texts})
    headers = [{"content-type", "application/json"}]
    endpoint = "#{url}/v1/embeddings"

    case http_client.(:post, endpoint, body, headers, recv_timeout: 30_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        parsed = if is_binary(resp_body), do: Jason.decode!(resp_body), else: resp_body
        embeddings =
          parsed["data"]
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])
        {:ok, embeddings}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "embedding API error #{status}: #{String.slice(to_string(resp_body), 0..200)}"}

      {:error, reason} ->
        {:error, "embedding request failed: #{inspect(reason)}"}
    end
  end

  defp default_http_client(method, url, body, headers, opts) do
    req = Req.new(url: url, headers: headers, body: body, receive_timeout: opts[:recv_timeout] || 30_000)

    case Req.request(req, method: method) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, err} -> {:error, err}
    end
  end

  defp config(key, default) do
    Application.get_env(:exclaw, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
