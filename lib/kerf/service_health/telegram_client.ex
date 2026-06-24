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

  @spec send_message(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(message, opts \\ [])

  def send_message(_message, _opts) do
    raise "not implemented: TelegramClient.send_message/2"
  end
end
