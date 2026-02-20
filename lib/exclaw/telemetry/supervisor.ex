defmodule ExClaw.Telemetry.Supervisor do
  @moduledoc """
  Supervises the Telemetry.Logger GenServer.
  """
  use Supervisor

  alias ExClaw.Telemetry.Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    logger_name = Keyword.get(opts, :logger_name, Logger)

    logger_opts =
      Keyword.get(opts, :logger_opts, [])
      |> Keyword.put(:name, logger_name)

    children = [
      {Logger, logger_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
