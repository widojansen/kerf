defmodule Kerf.ServiceHealth.TelegramClient do
  @moduledoc """
  Telegram `sendMessage` client for the izi2connect alert bot. See
  `docs/specs/SPEC_03_MONITOR_WORKER.md`.

  Token comes from the vault key `izimotive/izi2connect_telegram_token` (Spec 1).
  Chat id is tenant config — `Application.get_env(:kerf, __MODULE__)[:chat_id]`,
  set in `runtime.exs` from `IZI2CONNECT_TELEGRAM_CHAT_ID` — never a hardcoded
  module attribute. Separate bot from Tina (`@tina_exclaw_bot`), locked decision.

  HTTP client and vault fetch are injectable via `opts` (function-injection
  convention) so tests run without network or a real token/chat.

  Built and fully tested this spec but NOT called by `MonitorWorker` — Spec 3 is
  log-only; the live send is the Spec 4 flip.

  RED SKELETON: body raises; GREEN implements.
  """

  @vault_key "izimotive/izi2connect_telegram_token"

  @spec send_message(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(message, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    vault_fetch = Keyword.get(opts, :vault_fetch, &default_vault_fetch/1)

    case vault_fetch.(@vault_key) do
      {:ok, token} ->
        url = "https://api.telegram.org/bot#{token}/sendMessage"
        chat_id = Application.get_env(:kerf, __MODULE__, [])[:chat_id]
        body = Jason.encode!(%{chat_id: chat_id, text: message})
        headers = [{"content-type", "application/json; charset=utf-8"}]

        case http_client.(:post, url, body, headers, []) do
          {:ok, %{status: 200, body: resp_body}} ->
            if telegram_ok?(resp_body),
              do: {:ok, resp_body},
              else: {:error, {:telegram, resp_body}}

          {:ok, %{status: status, body: resp_body}} ->
            {:error, {:http_status, status, resp_body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:vault, reason}}
    end
  end

  # --- internal ---

  defp telegram_ok?(body) when is_map(body), do: body["ok"] == true

  defp telegram_ok?(body) when is_binary(body) do
    match?({:ok, %{"ok" => true}}, Jason.decode(body))
  end

  defp telegram_ok?(_), do: false

  defp default_http_client(method, url, body, headers, _opts) do
    case Req.request(method: method, url: url, body: body, headers: headers, retry: false) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, err} -> {:error, err}
    end
  end

  defp default_vault_fetch(name) do
    case Kerf.CredentialVault.get_by_name(name) do
      {:ok, %{decrypted_data: data}} when is_map(data) ->
        case data["key"] || data["token"] do
          nil -> {:error, :missing_secret}
          secret -> {:ok, secret}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
