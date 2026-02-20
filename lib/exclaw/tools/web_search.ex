defmodule ExClaw.Tools.WebSearch do
  @moduledoc """
  Web search via self-hosted SearXNG instance.

  Sends queries to SearXNG's JSON API and formats results
  as a numbered list. HTTP client is injectable for testing.
  """

  # --- Public API ---

  @doc """
  Search the web using SearXNG.

  Input: `%{"query" => "search terms", "count" => 5}`
  count is optional (default 5, clamped to 1..10).

  Returns `{:ok, formatted_string}` or `{:error, reason}`.
  """
  def search(input, opts \\ []) do
    with {:ok, %{query: query, count: count}} <- validate_input(input) do
      do_search(query, count, opts)
    end
  end

  @doc "Validate and normalize search input."
  def validate_input(%{"query" => query} = input) when is_binary(query) do
    if String.trim(query) == "" do
      {:error, "missing or empty query"}
    else
      count =
        (input["count"] || 5)
        |> max(1)
        |> min(10)

      {:ok, %{query: String.trim(query), count: count}}
    end
  end

  def validate_input(%{"query" => _}), do: {:error, "query must be a string"}
  def validate_input(_), do: {:error, "missing or empty query"}

  @doc "Build the SearXNG search URL."
  def build_url(base_url, query, _count) do
    encoded_query = URI.encode_www_form(query)
    "#{base_url}/search?q=#{encoded_query}&format=json&pageno=1"
  end

  @doc "Parse SearXNG JSON response body into a list of result maps."
  def parse_response(body) when is_map(body) do
    {:ok, Map.get(body, "results", [])}
  end

  def parse_response(_), do: {:error, "unexpected response format"}

  @doc "Format search results as a numbered list string."
  def format_results(query, []) do
    "No results found for: \"#{query}\""
  end

  def format_results(query, results) when is_list(results) do
    header = "Search results for: \"#{query}\"\n"

    entries =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, idx} ->
        title = result["title"] || "(no title)"
        url = result["url"] || ""
        content = result["content"] || ""

        url_line = if url != "", do: "   #{url}\n", else: ""
        content_line = if content != "", do: "   #{content}\n", else: ""

        "#{idx}. #{title}\n#{url_line}#{content_line}"
      end)
      |> Enum.join("\n")

    header <> "\n" <> entries
  end

  # --- Private ---

  defp do_search(query, count, opts) do
    config = Application.get_env(:exclaw, __MODULE__, [])
    base_url = Keyword.get(opts, :searxng_url, config[:searxng_url] || "http://localhost:8080")
    timeout = Keyword.get(opts, :timeout, config[:timeout] || 10_000)
    http_client = Keyword.get(opts, :http_client, &default_http_client/2)

    url = build_url(base_url, query, count)

    case http_client.(url, timeout: timeout) do
      {:ok, %{status: status}} when status >= 400 ->
        {:error, "SearXNG error #{status}"}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, results} = parse_response(body)
        trimmed = Enum.take(results, count)
        {:ok, format_results(query, trimmed)}

      {:ok, %{status: 200, body: _body}} ->
        {:error, "unexpected response: could not parse SearXNG response"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  end

  defp default_http_client(url, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    case Req.get(url, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
