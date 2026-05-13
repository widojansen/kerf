defmodule Kerf.Agents.EmailTriage.DigestCronTest do
  # Tests the cron-expression validation helper used at boot to wire the
  # Oban.Plugins.Cron crontab entry. Pure validation logic — does not touch
  # Oban itself.
  use ExUnit.Case, async: false

  alias Kerf.Agents.EmailTriage.DigestCron

  # ---------- env-driven cron expression ----------

  describe "expression!/0" do
    setup do
      previous = System.get_env("EMAIL_DIGEST_CRON")
      on_exit(fn ->
        case previous do
          nil -> System.delete_env("EMAIL_DIGEST_CRON")
          v -> System.put_env("EMAIL_DIGEST_CRON", v)
        end
      end)

      :ok
    end

    test "valid cron expression from env var loads and returns it verbatim" do
      System.put_env("EMAIL_DIGEST_CRON", "*/15 * * * *")
      assert DigestCron.expression!() == "*/15 * * * *"
    end

    test "invalid cron expression at boot fails fast (raises)" do
      # Boot-time validation must fail loud — operators see the error at deploy,
      # not silently three days later when the cron should have fired.
      System.put_env("EMAIL_DIGEST_CRON", "this is not a cron expression")

      assert_raise RuntimeError, ~r/EMAIL_DIGEST_CRON/, fn ->
        DigestCron.expression!()
      end
    end
  end
end
