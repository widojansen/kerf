defmodule Kerf.ServiceHealth.MonitorObanWiringTest do
  # Section D of SPEC_03_MONITOR_WORKER.md — Oban queue + Cron wiring.
  # No DB. The :monitoring queue lives in config.exs (present in :test); the Cron
  # plugin lives in runtime.exs and is gated out of :test, so the crontab is read
  # via Config.Reader.read!(env: :prod) — which evaluates DigestCron.expression!().
  use ExUnit.Case, async: true

  alias Kerf.ServiceHealth.MonitorWorker

  @seven_days 7 * 24 * 3600

  test "22. :monitoring queue is configured in the Oban queues" do
    queues = Application.get_env(:kerf, Oban)[:queues]
    assert Keyword.has_key?(queues, :monitoring),
           "expected :monitoring in Oban queues, got: #{inspect(queues)}"
  end

  describe "runtime.exs plugins (read via Config.Reader, env: :prod)" do
    setup do
      cfg = Config.Reader.read!("config/runtime.exs", env: :prod)
      {:ok, plugins: cfg[:kerf][Oban][:plugins]}
    end

    test "23. plugins list contains BOTH Pruner (7-day) and Cron (restate-Pruner guard)", %{plugins: plugins} do
      pruner = Enum.find(plugins, fn p -> match?({Oban.Plugins.Pruner, _}, p) end)
      assert pruner, "expected Oban.Plugins.Pruner present, got: #{inspect(plugins)}"
      {Oban.Plugins.Pruner, pruner_opts} = pruner
      assert pruner_opts[:max_age] == @seven_days

      cron = Enum.find(plugins, fn p -> match?({Oban.Plugins.Cron, _}, p) end)
      assert cron, "expected Oban.Plugins.Cron present, got: #{inspect(plugins)}"
      {Oban.Plugins.Cron, cron_opts} = cron
      crontab = cron_opts[:crontab]

      # The existing Digest entry must survive AND the monitoring entry must be added.
      assert Enum.any?(crontab, fn {_expr, mod} ->
               mod == Kerf.Agents.EmailTriage.DigestWorker
             end),
             "expected the existing DigestWorker cron entry to survive, got: #{inspect(crontab)}"

      assert Enum.any?(crontab, fn {_expr, mod} -> mod == MonitorWorker end),
             "expected a MonitorWorker cron entry, got: #{inspect(crontab)}"
    end

    test "24. Cron schedules MonitorWorker at \"*/5 * * * *\"", %{plugins: plugins} do
      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, fn p -> match?({Oban.Plugins.Cron, _}, p) end) || {Oban.Plugins.Cron, []}

      crontab = cron_opts[:crontab] || []

      assert Enum.any?(crontab, fn entry -> entry == {"*/5 * * * *", MonitorWorker} end),
             "expected {\"*/5 * * * *\", MonitorWorker} in crontab, got: #{inspect(crontab)}"
    end
  end
end
