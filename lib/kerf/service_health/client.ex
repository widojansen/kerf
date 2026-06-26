defmodule Kerf.ServiceHealth.Client do
  @moduledoc """
  Authenticated HTTP client for the izi monitoring `health-context` endpoint.

  Reads the API key from the credential vault, issues a bounded-retry GET with a
  per-request timeout, and parses the JSON into a `Kerf.ServiceHealth.Context`.

  Dependency injection via `opts` (`:http_client`, `:vault_fetch`) with production
  defaults resolved from `Application.get_env(:kerf, __MODULE__)`, so the zero-arg
  `fetch_health_context/0` form routes through the same code path. See
  `docs/specs/SPEC_01_HEALTH_CLIENT.md`.

  ## Synchronous and blocking

  `fetch_health_context/1` is synchronous: it runs in the caller's process and
  blocks until the request succeeds or retries are exhausted — worst case roughly
  `max_attempts × timeout` plus the inter-attempt delays (~90s at the defaults:
  3 × 30s + 2 × 200ms). Callers that must not block (e.g. a GenServer answering
  other messages) should run it off their own process.
  """

  require Logger

  alias Kerf.ServiceHealth.Context

  @health_url "https://izi-monitoring.orangestack.app/api/monitoring/health-context"
  @api_key_credential "izimotive/izi_monitoring_api_key"
  @telegram_credential "izimotive/izi2connect_telegram_token"
  @auth_header "x-api-key"

  # 30s matches the legacy Python script — the tenant service can take 15–20s
  # under load, and a shorter timeout risks bailing during the exact incident
  # this monitor exists to catch. Still well under the 5-minute cadence.
  @default_timeout 30_000
  @default_max_attempts 3
  @default_retry_delay 200

  @spec fetch_health_context(keyword()) :: {:ok, Context.t()} | {:error, term()}
  def fetch_health_context(opts \\ []) when is_list(opts) do
    http_client = Keyword.get(opts, :http_client, default_http_client())
    vault_fetch = Keyword.get(opts, :vault_fetch, default_vault_fetch())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    retry_delay = Keyword.get(opts, :retry_delay, @default_retry_delay)

    case vault_fetch.(@api_key_credential) do
      {:ok, api_key} ->
        request_with_retry(http_client, api_key, timeout, max_attempts, retry_delay, 1)

      {:error, reason} ->
        {:error, {:vault, reason}}
    end
  end

  @doc """
  Fetch the izi2connect Telegram token from the vault.

  Vault-wiring coverage only for this spec — the token is NOT otherwise used
  until Spec 3.
  """
  @spec fetch_telegram_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_telegram_token(opts \\ []) when is_list(opts) do
    vault_fetch = Keyword.get(opts, :vault_fetch, default_vault_fetch())
    vault_fetch.(@telegram_credential)
  end

  # --- Request + retry ---

  defp request_with_retry(http_client, api_key, timeout, max_attempts, retry_delay, attempt) do
    headers = [{@auth_header, api_key}]
    http_opts = [receive_timeout: timeout]

    case http_client.(:get, @health_url, nil, headers, http_opts) do
      {:ok, %{status: 200, body: body}} ->
        decode_body(body)

      {:ok, %{status: status}} when status >= 500 ->
        retry_or_fail(
          http_client,
          api_key,
          timeout,
          max_attempts,
          retry_delay,
          attempt,
          {:http_status, status}
        )

      {:ok, %{status: status, body: body}} ->
        # 4xx (and any other non-200, non-5xx): surface immediately, no retry.
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        if transient?(reason) do
          retry_or_fail(
            http_client,
            api_key,
            timeout,
            max_attempts,
            retry_delay,
            attempt,
            tag_error(reason)
          )
        else
          {:error, reason}
        end
    end
  end

  defp retry_or_fail(
         http_client,
         api_key,
         timeout,
         max_attempts,
         retry_delay,
         attempt,
         tagged_error
       ) do
    if attempt < max_attempts do
      if retry_delay > 0, do: Process.sleep(retry_delay)
      request_with_retry(http_client, api_key, timeout, max_attempts, retry_delay, attempt + 1)
    else
      # A monitoring component must not give up silently.
      Logger.warning(
        "[ServiceHealth.Client] retries exhausted after #{max_attempts} attempts, " <>
          "giving up: #{inspect(tagged_error)}"
      )

      {:error, tagged_error}
    end
  end

  # --- Transient-error classification ---

  defp transient?(:timeout), do: true
  defp transient?(:closed), do: true
  defp transient?(:econnrefused), do: true
  defp transient?(:connect_timeout), do: true
  defp transient?(%{reason: reason}), do: transient?(reason)
  defp transient?(_), do: false

  defp tag_error(:timeout), do: {:timeout, :timeout}
  defp tag_error(%{reason: :timeout} = err), do: {:timeout, err}
  defp tag_error(reason), do: {:transient, reason}

  # --- Body decoding ---

  defp decode_body(body) when is_map(body), do: {:ok, Context.from_map(body)}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, Context.from_map(map)}
      {:ok, _non_map} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_body(_), do: {:error, :invalid_payload}

  # --- Production defaults (resolved at call time; overridable via opts or app config) ---

  defp default_http_client do
    config()[:http_client] || (&real_http_client/5)
  end

  defp default_vault_fetch do
    config()[:vault_fetch] || (&real_vault_fetch/1)
  end

  defp config, do: Application.get_env(:kerf, __MODULE__, [])

  defp real_http_client(method, url, body, headers, http_opts) do
    req_opts = [url: url, method: method, headers: headers, retry: false] ++ http_opts
    req_opts = if body, do: Keyword.put(req_opts, :body, body), else: req_opts

    case Req.request(req_opts) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, err} -> {:error, err}
    end
  end

  defp real_vault_fetch(name) do
    case Kerf.CredentialVault.get_by_name(name) do
      {:ok, %{decrypted_data: data}} ->
        case extract_secret(data) do
          nil -> {:error, :missing_secret}
          secret -> {:ok, secret}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_secret(data) when is_map(data) do
    # decrypted_data is Jason.decode! output (string keys), so atom-key lookups
    # would be dead code — removed.
    data["key"] || data["token"]
  end

  defp extract_secret(_), do: nil
end
