defmodule ExClaw.Monitor.Supervisor do
  @moduledoc """
  Supervisor for the monitoring subsystem.

  Strategy: `rest_for_one` — if ProcessHealth crashes, TelemetryHandlers
  and Alerting restart too. If Alerting crashes alone, ProcessHealth and
  TelemetryHandlers keep running.

  Start order: ProcessHealth → TelemetryHandlers → Alerting.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    process_health_opts = Keyword.get(opts, :process_health_opts, [])
    alerting_opts = Keyword.get(opts, :alerting_opts, [])
    handlers_name = Keyword.get(opts, :telemetry_handlers_name, ExClaw.Monitor.TelemetryHandlers)

    # Default names if not provided
    health_opts =
      Keyword.put_new(process_health_opts, :name, ExClaw.Monitor.ProcessHealth)

    alert_opts =
      Keyword.put_new(alerting_opts, :name, ExClaw.Monitor.Alerting)

    children = [
      {ExClaw.Monitor.ProcessHealth, health_opts},
      {ExClaw.Monitor.TelemetryHandlers.Server, name: handlers_name},
      {ExClaw.Monitor.Alerting, alert_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
