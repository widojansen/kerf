defmodule Kerf.CredentialVault.TokenRefreshWorker do
  @moduledoc """
  Proactively refreshes expiring OAuth2 tokens.

  Runs on a timer (default 5 minutes). If an OAuth2 credential's access_token
  expires within the refresh threshold (default 10 minutes), it attempts a
  refresh using the stored refresh_token.

  On failure, logs a warning but does not crash.
  """
  use GenServer

  require Logger

  alias Kerf.CredentialVault

  @default_check_interval :timer.minutes(5)
  @default_refresh_threshold 600

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    vault = Keyword.get(opts, :vault, CredentialVault)
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    refresh_threshold = Keyword.get(opts, :refresh_threshold, @default_refresh_threshold)

    http_client =
      Keyword.get(opts, :http_client, &default_http_client/3)

    schedule_check(check_interval)

    {:ok,
     %{
       vault: vault,
       check_interval: check_interval,
       refresh_threshold: refresh_threshold,
       http_client: http_client
     }}
  end

  @impl true
  def handle_info(:check_tokens, state) do
    try do
      check_and_refresh(state)
    rescue
      e ->
        Logger.warning("TokenRefreshWorker check failed: #{inspect(e)}")
    end

    schedule_check(state.check_interval)
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_check(interval) do
    Process.send_after(self(), :check_tokens, interval)
  end

  defp check_and_refresh(state) do
    credentials = CredentialVault.list(state.vault, type: :oauth2)
    now = DateTime.utc_now()

    for cred <- credentials, needs_refresh?(cred, now, state.refresh_threshold) do
      refresh_credential(cred, state)
    end
  end

  defp needs_refresh?(%{expires_at: nil}, _now, _threshold), do: true

  defp needs_refresh?(%{expires_at: expires_at}, now, threshold) do
    DateTime.diff(expires_at, now) <= threshold
  end

  defp refresh_credential(cred_meta, state) do
    case CredentialVault.get(state.vault, cred_meta.id) do
      {:ok, cred} ->
        data = cred.decrypted_data

        case do_refresh(data, state.http_client) do
          {:ok, new_access_token, expires_in} ->
            new_data =
              data
              |> Map.put("access_token", new_access_token)

            expires_at =
              if expires_in do
                DateTime.utc_now() |> DateTime.add(expires_in)
              end

            CredentialVault.update(state.vault, cred.id, new_data,
              expires_at: expires_at,
              last_refreshed_at: DateTime.utc_now()
            )

            Logger.info("Refreshed OAuth2 token for #{cred_meta.name}")

          {:error, reason} ->
            Logger.warning(
              "Failed to refresh OAuth2 token for #{cred_meta.name}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning("Could not load credential #{cred_meta.id}: #{inspect(reason)}")
    end
  end

  defp do_refresh(data, http_client) do
    token_url = data["token_url"]
    refresh_token = data["refresh_token"]
    client_id = data["client_id"]
    client_secret = data["client_secret"]

    if is_nil(token_url) or is_nil(refresh_token) do
      {:error, :missing_refresh_config}
    else
      body =
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id || "",
          "client_secret" => client_secret || ""
        })

      headers = [{"content-type", "application/x-www-form-urlencoded"}]

      case http_client.(token_url, body, headers) do
        {:ok, %{status: 200, body: resp_body}} ->
          parsed = if is_binary(resp_body), do: Jason.decode!(resp_body), else: resp_body
          {:ok, parsed["access_token"], parsed["expires_in"]}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp default_http_client(url, body, headers) do
    case Req.post(url, body: body, headers: headers, receive_timeout: 10_000) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
