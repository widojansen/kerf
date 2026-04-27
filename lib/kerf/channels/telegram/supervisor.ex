defmodule Kerf.Channels.Telegram.Supervisor do
  @moduledoc """
  Supervisor for the Telegram channel GenServer.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    telegram_opts = Keyword.get(opts, :telegram_opts, [])

    children = [
      {Kerf.Channels.Telegram, telegram_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
