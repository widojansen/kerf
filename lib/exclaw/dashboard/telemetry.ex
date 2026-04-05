defmodule ExClaw.Dashboard.Telemetry do
  @moduledoc """
  Telemetry metrics definitions for Phoenix LiveDashboard.
  """
  import Telemetry.Metrics

  def metrics do
    [
      # VM Metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.atom", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        unit: {:native, :millisecond},
        tags: [:route]
      ),

      # Ecto Metrics
      summary("exclaw.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "Total Ecto query time"
      ),
      summary("exclaw.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "Time spent waiting for a database connection"
      )
    ]
  end
end
