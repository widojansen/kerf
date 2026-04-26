defmodule Kerf.Ingestors.Email.GmailClient do
  @moduledoc """
  Gmail REST API client using OAuth2 Bearer tokens for authentication.
  """

  @base_url "https://gmail.googleapis.com/gmail/v1/users/me"

  @doc """
  Fetch new emails since last sync.
  Uses history API if history_id provided, falls back to messages.list.
  Returns `{:ok, emails, new_history_id}` or `{:error, reason}`.
  """
  def fetch_new(access_token, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    history_id = Keyword.get(opts, :history_id)
    max_results = Keyword.get(opts, :max_results, 50)
    headers = build_auth_headers(access_token)

    if history_id do
      fetch_via_history(http_client, headers, history_id, opts)
    else
      fetch_via_list(http_client, headers, max_results, opts)
    end
  end

  @doc """
  Search for emails matching a Gmail search query.
  Returns `{:ok, emails}`.
  """
  def search(access_token, query, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    max_results = Keyword.get(opts, :max_results, 100)
    headers = build_auth_headers(access_token)

    url = "#{@base_url}/messages?q=#{URI.encode_www_form(query)}&maxResults=#{max_results}"

    case http_client.(:get, url, nil, headers, []) do
      {:ok, %{status: 200, body: body}} ->
        parsed = decode_json(body)
        message_ids = Map.get(parsed, "messages", []) |> Enum.map(& &1["id"])
        emails = Enum.map(message_ids, &fetch_full_message(http_client, headers, &1))
        {:ok, Enum.filter(emails, &(&1 != nil))}

      {:ok, %{status: status, body: body}} ->
        {:error, "Gmail search error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Gmail search failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Get a single email by message ID.
  """
  def get_message(access_token, message_id, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    headers = build_auth_headers(access_token)

    case fetch_full_message(http_client, headers, message_id) do
      nil -> {:error, "message not found"}
      email -> {:ok, email}
    end
  end

  @doc """
  Resolve a label name to its Gmail label ID, creating it if it doesn't exist.
  Returns `{:ok, label_id}` or `{:error, reason}`.
  """
  def resolve_label(access_token, label_name, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    headers = build_auth_headers(access_token)

    case http_client.(:get, "#{@base_url}/labels", nil, headers, []) do
      {:ok, %{status: 200, body: body}} ->
        parsed = decode_json(body)
        labels = parsed["labels"] || []

        case Enum.find(labels, fn l -> l["name"] == label_name end) do
          %{"id" => id} ->
            {:ok, id}

          nil ->
            create_body = Jason.encode!(%{"name" => label_name, "labelListVisibility" => "labelShow", "messageListVisibility" => "show"})

            case http_client.(:post, "#{@base_url}/labels", create_body, [{"content-type", "application/json"} | headers], []) do
              {:ok, %{status: 200, body: resp}} ->
                {:ok, decode_json(resp)["id"]}

              {:ok, %{status: status, body: resp}} ->
                {:error, "Gmail create label error #{status}: #{inspect(resp)}"}

              {:error, reason} ->
                {:error, "Gmail create label failed: #{inspect(reason)}"}
            end
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "Gmail list labels error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Gmail list labels failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Apply labels to a Gmail message.
  """
  def apply_labels(access_token, message_id, label_ids, opts \\ []) do
    modify_message(access_token, message_id, Keyword.merge([add: label_ids], opts))
  end

  @doc """
  Modify a Gmail message: add and/or remove labels.

  Options:
    - `:add` — list of label IDs to add
    - `:remove` — list of label IDs to remove
    - `:http_client` — injectable HTTP client
  """
  def modify_message(access_token, message_id, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    add_ids = Keyword.get(opts, :add, [])
    remove_ids = Keyword.get(opts, :remove, [])
    headers = build_auth_headers(access_token)
    url = "#{@base_url}/messages/#{message_id}/modify"
    body = Jason.encode!(%{"addLabelIds" => add_ids, "removeLabelIds" => remove_ids})

    case http_client.(:post, url, body, [{"content-type", "application/json"} | headers], []) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: resp}} -> {:error, "Gmail modify error #{status}: #{inspect(resp)}"}
      {:error, reason} -> {:error, "Gmail modify failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Parse a raw Gmail API message response into a structured email map.
  """
  def parse_message(msg) do
    payload = msg["payload"]
    headers_list = payload["headers"] || []

    %{
      id: msg["id"],
      thread_id: msg["threadId"],
      from: get_header(headers_list, "From") |> parse_address(),
      to: get_header(headers_list, "To") |> parse_address_list(),
      cc: get_header(headers_list, "Cc") |> parse_address_list(),
      subject: get_header(headers_list, "Subject"),
      body_text: extract_body(payload, "text/plain"),
      body_html: extract_body(payload, "text/html"),
      date: get_header(headers_list, "Date"),
      labels: msg["labelIds"] || [],
      snippet: msg["snippet"],
      history_id: msg["historyId"]
    }
  end

  @doc """
  Parse an email address string like "Name <email@example.com>" or "email@example.com".
  """
  def parse_address(nil), do: %{name: nil, email: nil}

  def parse_address(str) do
    str = String.trim(str)

    case Regex.run(~r/^"?([^"<]*?)"?\s*<([^>]+)>$/, str) do
      [_, name, email] ->
        name = String.trim(name)
        %{name: if(name == "", do: nil, else: name), email: String.trim(email)}

      _ ->
        if String.contains?(str, "@") do
          %{name: nil, email: str}
        else
          %{name: str, email: nil}
        end
    end
  end

  @doc """
  Parse a comma-separated list of email addresses.
  """
  def parse_address_list(nil), do: []
  def parse_address_list(""), do: []

  def parse_address_list(str) do
    str
    |> String.split(~r/,\s*/)
    |> Enum.map(&parse_address/1)
    |> Enum.reject(&(&1.email == nil))
  end

  @doc """
  Build authorization headers for Gmail API requests.
  """
  def build_auth_headers(access_token) do
    [{"authorization", "Bearer #{access_token}"}]
  end

  # --- Private ---

  defp fetch_via_history(http_client, headers, history_id, _opts) do
    fetch_history_pages(http_client, headers, history_id, [], nil)
  end

  defp fetch_history_pages(http_client, headers, history_id, acc_ids, page_token) do
    url = "#{@base_url}/history?startHistoryId=#{history_id}&historyTypes=messageAdded"
    url = if page_token, do: "#{url}&pageToken=#{page_token}", else: url

    case http_client.(:get, url, nil, headers, []) do
      {:ok, %{status: 200, body: body}} ->
        parsed = decode_json(body)
        new_history_id = parsed["historyId"]

        page_ids =
          (parsed["history"] || [])
          |> Enum.flat_map(fn h -> Map.get(h, "messagesAdded", []) end)
          |> Enum.map(& &1["message"]["id"])

        all_ids = acc_ids ++ page_ids

        case parsed["nextPageToken"] do
          nil ->
            emails =
              all_ids
              |> Enum.uniq()
              |> Enum.map(&fetch_full_message(http_client, headers, &1))
              |> Enum.filter(&(&1 != nil))

            {:ok, emails, new_history_id}

          next_token ->
            fetch_history_pages(http_client, headers, history_id, all_ids, next_token)
        end

      {:ok, %{status: 404}} ->
        {:error, :history_expired}

      {:ok, %{status: status, body: body}} ->
        {:error, "Gmail history error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Gmail history failed: #{inspect(reason)}"}
    end
  end

  defp fetch_via_list(http_client, headers, max_results, _opts) do
    fetch_list_pages(http_client, headers, max_results, [], nil)
  end

  defp fetch_list_pages(http_client, headers, max_results, _acc_ids, _page_token) do
    # Fetch only the first page — max_results controls how many we get.
    # Paginating through all messages is too slow and unnecessary for polling.
    url = "#{@base_url}/messages?maxResults=#{max_results}&labelIds=INBOX"

    case http_client.(:get, url, nil, headers, []) do
      {:ok, %{status: 200, body: body}} ->
        parsed = decode_json(body)
        page_ids = Map.get(parsed, "messages", []) |> Enum.map(& &1["id"])

        emails =
          page_ids
          |> Enum.map(&fetch_full_message(http_client, headers, &1))
          |> Enum.filter(&(&1 != nil))

        latest_history_id =
          case emails do
            [first | _] -> first.history_id
            [] -> nil
          end

        {:ok, emails, latest_history_id}

      {:ok, %{status: status, body: body}} ->
        {:error, "Gmail list error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Gmail list failed: #{inspect(reason)}"}
    end
  end

  defp fetch_full_message(http_client, headers, message_id) do
    url = "#{@base_url}/messages/#{message_id}?format=full"

    case http_client.(:get, url, nil, headers, []) do
      {:ok, %{status: 200, body: body}} ->
        body |> decode_json() |> parse_message()

      _ ->
        nil
    end
  end

  defp decode_json(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_json(body) when is_map(body), do: body
  defp decode_json(body) when is_list(body), do: body

  defp get_header(headers, name) do
    case Enum.find(headers, &(String.downcase(&1["name"]) == String.downcase(name))) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp extract_body(payload, mime_type) do
    cond do
      payload["mimeType"] == mime_type and payload["body"]["data"] ->
        decode_body(payload["body"]["data"])

      parts = payload["parts"] ->
        case Enum.find(parts, &(&1["mimeType"] == mime_type)) do
          %{"body" => %{"data" => data}} -> decode_body(data)
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp decode_body(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} -> decoded
      :error ->
        case Base.url_decode64(data) do
          {:ok, decoded} -> decoded
          :error -> data
        end
    end
  end

  defp default_http_client(method, url, body, headers, _opts) do
    req = gmail_req()
    opts = [url: url, headers: headers, method: method]
    opts = if body, do: Keyword.put(opts, :body, body), else: opts

    case Req.request(req, opts) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, err} -> {:error, err}
    end
  end

  # Reuse a single Req client per process to avoid spawning a new Finch pool per request
  defp gmail_req do
    case Process.get(:gmail_req) do
      nil ->
        req = Req.new(receive_timeout: 30_000, retry: false)
        Process.put(:gmail_req, req)
        req

      req ->
        req
    end
  end
end
