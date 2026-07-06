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

  @doc """
  Decide whether `input` should trigger a Telegram notification, relative to `now`.

  `input` is a superset of a triage result; only these keys are read:

    * `:labels` — `[String.t()]` (from `source_metadata["labels"]`)
    * `:date`   — `String.t() | nil` (RFC2822 `Date` header from `source_metadata["date"]`)

  Extra keys are ignored. See the module doc for the rule order.
  """
  @spec notify?(map(), DateTime.t()) :: boolean()
  def notify?(_input, _now), do: raise("not implemented")

  @doc """
  Parse an RFC2822 `Date` header string into a UTC `DateTime`.

  Returns `{:ok, DateTime.t()}` (normalised to UTC) or `:error` on a malformed
  or unparseable input.
  """
  @spec parse_date(String.t() | nil) :: {:ok, DateTime.t()} | :error
  def parse_date(_raw), do: raise("not implemented")
end
