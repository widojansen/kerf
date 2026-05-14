defmodule Kerf.Agents.EmailTriage.DigestCron do
  @moduledoc """
  Resolves the digest cron expression from `EMAIL_DIGEST_CRON` env var with
  a daily-08:00 default. Validation is via `Crontab.CronExpression.Parser.parse/1`
  (already a transitive dep via `:quantum`).

  Used by `config/runtime.exs` to populate the `Oban.Plugins.Cron` crontab at
  boot. Invalid expressions raise — fail-fast at startup rather than silent
  cron drift.
  """

  @default "0 8 * * *"

  @doc "Return the raw cron expression (env var or default)."
  def expression do
    System.get_env("EMAIL_DIGEST_CRON") || @default
  end

  @doc """
  Return the cron expression, raising if it fails to parse.

  Called at boot time from `config/runtime.exs` so misconfiguration surfaces
  immediately at deploy rather than silently three days later.
  """
  def expression! do
    expr = expression()

    case Crontab.CronExpression.Parser.parse(expr) do
      {:ok, _parsed} ->
        expr

      {:error, reason} ->
        raise "Invalid EMAIL_DIGEST_CRON #{inspect(expr)}: #{inspect(reason)}"
    end
  end
end
