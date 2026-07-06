defmodule Kerf.Agents.EmailTriage.NotifyGuard do
  @moduledoc """
  Universal notification guard for the email-triage notify path
  (SPEC C amendment — `docs/specs/spec-c-notify-guard.md`).

  Pure predicate. Decides whether a triage `result` should reach Telegram at the
  emission seam. Silence is forced when EITHER condition holds:

      notify?  ==  NOT ("SENT" ∈ labels)  AND  (received_date ≥ now − MAX_AGE)

  `MAX_AGE` defaults to 24h and is tunable without redeploy via:

      config :kerf, #{inspect(__MODULE__)}, max_age_hours: 24
  """

  require Logger

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @default_max_age_hours 24

  @doc """
  Decide whether `input` should trigger a Telegram notification, relative to `now`.

  `input` is a superset of a triage result; only these keys are read:

    * `:labels` — `[String.t()]` (from `source_metadata["labels"]`)
    * `:date`   — `String.t() | nil` (RFC2822 `Date` header from `source_metadata["date"]`)

  Extra keys are ignored. Rules, in order:

    1. `"SENT" in labels` → `false` (never announce your own sent mail).
    2. Parse `:date`:
       * parse fails or `nil` → `true` (fail-open; logged at `:debug`).
       * `received_at < now − MAX_AGE` → `false`.
       * else → `true`.
  """
  @spec notify?(map(), DateTime.t()) :: boolean()
  def notify?(input, %DateTime{} = now) when is_map(input) do
    labels = Map.get(input, :labels, []) || []

    if "SENT" in labels do
      false
    else
      fresh_enough?(Map.get(input, :date), now)
    end
  end

  @doc """
  Parse an RFC2822 `Date` header string into a UTC `DateTime`.

  Returns `{:ok, DateTime.t()}` (normalised to UTC) or `:error` on a malformed
  or unparseable input. The optional leading weekday (`"Mon, "`) and a trailing
  `(...)` zone comment are tolerated; numeric offsets and the common alphabetic
  UTC zones (`UT`/`GMT`/`UTC`/`Z`) are supported.
  """
  @spec parse_date(String.t() | nil) :: {:ok, DateTime.t()} | :error
  def parse_date(raw) when is_binary(raw) do
    raw
    |> strip_weekday()
    |> strip_zone_comment()
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> parse_tokens()
  end

  def parse_date(_), do: :error

  # ---------- notify? helpers ----------

  defp fresh_enough?(date, now) do
    case parse_date(date) do
      {:ok, received_at} ->
        threshold = DateTime.add(now, -max_age_hours() * 3600, :second)
        # received_at ≥ threshold ⇒ notify; strictly older ⇒ silent.
        DateTime.compare(received_at, threshold) != :lt

      :error ->
        Logger.debug("[NotifyGuard] unparseable/absent Date header, failing open: #{inspect(date)}")
        true
    end
  end

  defp max_age_hours do
    Application.get_env(:kerf, __MODULE__, [])
    |> Keyword.get(:max_age_hours, @default_max_age_hours)
  end

  # ---------- RFC2822 parsing ----------

  # Drop an optional "Dow, " prefix; a bare date (no weekday) has no comma.
  defp strip_weekday(str) do
    case String.split(str, ",", parts: 2) do
      [_dow, rest] -> rest
      [only] -> only
    end
  end

  # Gmail sometimes appends a "(UTC)" / "(PDT)" comment after the offset.
  defp strip_zone_comment(str), do: String.replace(str, ~r/\s*\([^)]*\)\s*$/, "")

  defp parse_tokens([day, mon, year, time, offset]) do
    with {d, ""} <- Integer.parse(day),
         {:ok, month} <- Map.fetch(@months, mon),
         {y, ""} <- Integer.parse(year),
         {:ok, {h, min, s}} <- parse_time(time),
         {:ok, offset_seconds} <- parse_offset(offset),
         {:ok, naive} <- NaiveDateTime.new(y, month, d, h, min, s),
         {:ok, wall} <- DateTime.from_naive(naive, "Etc/UTC") do
      # `wall` is the local clock time; UTC = wall − offset.
      {:ok, DateTime.add(wall, -offset_seconds, :second)}
    else
      _ -> :error
    end
  end

  defp parse_tokens(_), do: :error

  # Seconds are optional in RFC2822 (HH:MM or HH:MM:SS).
  defp parse_time(time) do
    case String.split(time, ":") do
      [hh, mm, ss] -> build_time(hh, mm, ss)
      [hh, mm] -> build_time(hh, mm, "00")
      _ -> :error
    end
  end

  defp build_time(hh, mm, ss) do
    with {h, ""} <- Integer.parse(hh),
         {min, ""} <- Integer.parse(mm),
         {s, ""} <- Integer.parse(ss) do
      {:ok, {h, min, s}}
    else
      _ -> :error
    end
  end

  defp parse_offset(<<sign, h1, h2, m1, m2>>) when sign in [?+, ?-] do
    with {hours, ""} <- Integer.parse(<<h1, h2>>),
         {mins, ""} <- Integer.parse(<<m1, m2>>) do
      total = hours * 3600 + mins * 60
      {:ok, if(sign == ?-, do: -total, else: total)}
    else
      _ -> :error
    end
  end

  defp parse_offset(zone) when zone in ["UT", "GMT", "UTC", "Z"], do: {:ok, 0}
  defp parse_offset(_), do: :error
end
