defmodule Kerf.CredentialVault.Proxy do
  @moduledoc """
  Makes authenticated HTTP requests on behalf of agents using lease tokens.

  The agent never sees the real credential — the Proxy injects the Authorization
  header server-side. On 401, it attempts one token refresh before failing.

  Not a GenServer — a stateless module called directly by agents.
  """

  require Logger

  alias Kerf.CredentialVault
  alias Kerf.CredentialVault.LeaseManager

  @doc """
  Make an authenticated HTTP request using a lease.

  Options:
    - `:http_client` - fn(method, url, opts) -> {:ok, resp} | {:error, reason}
    - `:lease_manager` - LeaseManager name (default: LeaseManager)
    - `:vault` - Vault name (default: CredentialVault)
    - `:rate_table` - ETS table for rate limiting (optional)
    - `:headers` - additional headers
    - `:body` - request body
    - `:params` - query params
  """
  def request(lease, method, url, opts \\ []) do
    lm = Keyword.get(opts, :lease_manager, LeaseManager)
    http_client = Keyword.get(opts, :http_client, &default_http_client/3)
    rate_table = Keyword.get(opts, :rate_table)

    with :ok <- check_lease_valid(lm, lease),
         :ok <- check_rate_limit(rate_table, lease.credential_id) do
      do_request(lease, method, url, http_client, opts)
    end
  end

  # --- Private ---

  defp check_lease_valid(lm, lease) do
    if LeaseManager.valid?(lm, lease.id) do
      :ok
    else
      {:error, :lease_expired}
    end
  end

  defp check_rate_limit(nil, _credential_id), do: :ok

  defp check_rate_limit(table, credential_id) do
    case :ets.lookup(table, credential_id) do
      [{^credential_id, bucket}] ->
        now = System.monotonic_time(:millisecond)
        elapsed = (now - bucket.last_refill) / 1000.0
        refilled = min(bucket.max_tokens, bucket.tokens + elapsed * bucket.refill_rate)

        if refilled >= 1.0 do
          :ets.insert(table, {credential_id, %{bucket | tokens: refilled - 1.0, last_refill: now}})
          :ok
        else
          retry_after = trunc((1.0 - refilled) / bucket.refill_rate * 1000)
          {:error, {:rate_limited, retry_after}}
        end

      [] ->
        :ok
    end
  end

  defp do_request(lease, method, url, http_client, opts) do
    headers = build_headers(lease.access_token, Keyword.get(opts, :headers, []))
    req_opts = [headers: headers] ++ build_req_opts(opts)

    case http_client.(method, url, req_opts) do
      {:ok, %{status: 401} = _resp} ->
        handle_401_retry(lease, method, url, http_client, opts)

      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp handle_401_retry(lease, method, url, http_client, opts) do
    vault = Keyword.get(opts, :vault, CredentialVault)

    case CredentialVault.get(vault, lease.credential_id) do
      {:ok, cred} ->
        data = cred.decrypted_data

        case refresh_token(data, http_client) do
          {:ok, new_token, expires_in} ->
            # Update the credential in vault
            new_data = Map.put(data, "access_token", new_token)

            CredentialVault.update(vault, cred.id, new_data,
              expires_at:
                if(expires_in, do: DateTime.utc_now() |> DateTime.add(expires_in)),
              last_refreshed_at: DateTime.utc_now()
            )

            # Retry with new token
            headers =
              build_headers(new_token, Keyword.get(opts, :headers, []))

            req_opts = [headers: headers] ++ build_req_opts(opts)

            case http_client.(method, url, req_opts) do
              {:ok, %{status: 401}} -> {:error, :refresh_failed}
              {:ok, resp} -> {:ok, resp}
              {:error, reason} -> {:error, {:request_failed, reason}}
            end

          {:error, _reason} ->
            {:error, :refresh_failed}
        end

      {:error, _} ->
        {:error, :refresh_failed}
    end
  end

  defp refresh_token(data, http_client) do
    token_url = data["token_url"]
    refresh_token_val = data["refresh_token"]

    if is_nil(token_url) or is_nil(refresh_token_val) do
      {:error, :no_refresh_config}
    else
      body =
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token_val,
          "client_id" => data["client_id"] || "",
          "client_secret" => data["client_secret"] || ""
        })

      headers = [{"content-type", "application/x-www-form-urlencoded"}]

      case http_client.(:post, token_url, headers: headers, body: body) do
        {:ok, %{status: 200, body: resp_body}} ->
          parsed = Jason.decode!(resp_body)
          {:ok, parsed["access_token"], parsed["expires_in"]}

        {:ok, %{status: status}} ->
          {:error, {:refresh_http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_headers(access_token, extra_headers) do
    [{"authorization", "Bearer #{access_token}"} | extra_headers]
  end

  defp build_req_opts(opts) do
    Enum.flat_map([:body, :params], fn key ->
      case Keyword.get(opts, key) do
        nil -> []
        val -> [{key, val}]
      end
    end)
  end

  defp default_http_client(method, url, opts) do
    case Req.request(method: method, url: url, headers: Keyword.get(opts, :headers, []),
           body: Keyword.get(opts, :body),
           params: Keyword.get(opts, :params),
           receive_timeout: 30_000
         ) do
      {:ok, resp} ->
        {:ok, %{status: resp.status, headers: resp.headers, body: resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
