defmodule Kerf.Tools.WebFetch do
  @moduledoc """
  Fetches and extracts readable content from web URLs.

  Includes SSRF protection (blocks private/internal IPs) and
  content size limits. Uses Floki for HTML content extraction.
  """

  @blocked_hostnames ["localhost"]
  @strip_elements ~w(script style nav footer header aside iframe noscript)

  # --- Public API ---

  @doc """
  Fetch a URL and extract its content.

  Input: `%{"url" => "https://...", "extract_mode" => "text"|"markdown"}`
  extract_mode is optional, defaults to "text".

  Returns `{:ok, formatted_string}` or `{:error, reason}`.
  """
  def fetch(input, opts \\ []) do
    with {:ok, url} <- extract_url(input),
         :ok <- validate_url(url),
         {:ok, host} <- extract_host(url),
         :ok <- check_ssrf(host) do
      do_fetch(url, opts)
    end
  end

  @doc "Validate that a URL is well-formed and uses http/https."
  def validate_url(url) when is_binary(url) do
    cond do
      url == "" ->
        {:error, "empty URL"}

      true ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            :ok

          _ ->
            {:error, "invalid URL: must be http or https"}
        end
    end
  end

  def validate_url(_), do: {:error, "invalid URL"}

  @doc """
  Check if a hostname resolves to a blocked (private/internal) IP.
  Accepts hostnames or IP address strings.
  """
  def check_ssrf(host) when is_binary(host) do
    if host in @blocked_hostnames do
      {:error, "SSRF blocked: #{host} is not allowed"}
    else
      case parse_or_resolve_ip(host) do
        {:ok, ip_tuple} ->
          if private_ip?(ip_tuple) do
            {:error, "SSRF blocked: #{host} resolves to a private/internal IP"}
          else
            :ok
          end

        {:error, _} ->
          # DNS resolution failed — block to be safe
          {:error, "SSRF blocked: cannot resolve #{host}"}
      end
    end
  end

  @doc "Extract content from an HTML string using Floki."
  def extract_content(html) when is_binary(html) do
    if html == "" do
      {:ok, %{title: nil, content: ""}}
    else
      case Floki.parse_document(html) do
        {:ok, doc} ->
          title = extract_title(doc)
          cleaned = strip_unwanted(doc)
          content = extract_main_content(cleaned)
          text = html_to_text(content)
          {:ok, %{title: title, content: String.trim(text)}}

        {:error, _} ->
          {:ok, %{title: nil, content: ""}}
      end
    end
  end

  @doc "Truncate text to max_chars, appending [truncated] marker if needed."
  def truncate(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n\n[truncated]"
    else
      text
    end
  end

  # --- Private ---

  defp extract_url(%{"url" => url}) when is_binary(url) and byte_size(url) > 0, do: {:ok, url}
  defp extract_url(_), do: {:error, "missing or invalid 'url' parameter"}

  defp extract_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, "cannot extract host from URL"}
    end
  end

  defp do_fetch(url, opts) do
    config = Application.get_env(:exclaw, __MODULE__, [])
    timeout = Keyword.get(opts, :timeout, config[:timeout] || 15_000)
    max_chars = Keyword.get(opts, :max_content_chars, config[:max_content_chars] || 50_000)
    user_agent = Keyword.get(opts, :user_agent, config[:user_agent] || "Kerf/0.1")
    http_client = Keyword.get(opts, :http_client, &default_http_client/2)

    case http_client.(url, timeout: timeout, user_agent: user_agent) do
      {:ok, %{status: status}} when status >= 400 ->
        {:error, "HTTP error #{status}"}

      {:ok, %{status: 200, headers: headers, body: body}} ->
        content_type = get_content_type(headers)
        format_response(url, body, content_type, max_chars)

      {:ok, %{status: status, headers: headers, body: body}} when status in 200..399 ->
        content_type = get_content_type(headers)
        format_response(url, body, content_type, max_chars)

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  end

  defp default_http_client(url, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    user_agent = Keyword.get(opts, :user_agent, "Kerf/0.1")

    case Req.get(url, receive_timeout: timeout, headers: [{"user-agent", user_agent}]) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        flat_headers =
          headers
          |> Enum.into(%{}, fn {k, v} ->
            {String.downcase(k), if(is_list(v), do: List.first(v), else: v)}
          end)

        {:ok, %{status: status, headers: flat_headers, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_content_type(headers) when is_map(headers) do
    (headers["content-type"] || "")
    |> String.downcase()
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp format_response(url, body, content_type, max_chars) do
    if String.contains?(content_type, "html") do
      {:ok, %{title: title, content: content}} = extract_content(body)
      text = truncate(content, max_chars)
      title_line = if title, do: "Title: #{title}\n", else: ""

      {:ok, "URL: #{url}\n#{title_line}---\n#{text}"}
    else
      text = truncate(body, max_chars)
      {:ok, "URL: #{url}\n---\n#{text}"}
    end
  end

  # --- SSRF IP checking ---

  defp parse_or_resolve_ip(host) do
    charlist = String.to_charlist(host)

    # Try parsing as IPv4 literal first
    case :inet.parse_address(charlist) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple}

      {:error, _} ->
        # Not a literal IP — resolve via DNS
        case :inet.getaddr(charlist, :inet) do
          {:ok, ip_tuple} -> {:ok, ip_tuple}
          {:error, _} -> {:error, :nxdomain}
        end
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, 0, 0, 0}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true  # ::1
  defp private_ip?(_), do: false

  # --- HTML extraction ---

  defp extract_title(doc) do
    case Floki.find(doc, "title") do
      [{_, _, children} | _] -> Floki.text(children) |> String.trim()
      _ -> nil
    end
  end

  defp strip_unwanted(doc) do
    Enum.reduce(@strip_elements, doc, fn tag, acc ->
      Floki.filter_out(acc, tag)
    end)
  end

  defp extract_main_content(doc) do
    cond do
      (nodes = Floki.find(doc, "article")) != [] -> nodes
      (nodes = Floki.find(doc, "main")) != [] -> nodes
      (nodes = Floki.find(doc, "[role=main]")) != [] -> nodes
      (nodes = Floki.find(doc, "body")) != [] -> nodes
      true -> doc
    end
  end

  defp html_to_text(nodes) when is_list(nodes) do
    nodes
    |> Floki.text(sep: "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
