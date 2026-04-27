defmodule Kerf.Channels.WhatsApp.Supervisor do
  @moduledoc """
  Supervisor for the WhatsApp channel GenServer.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    wa_opts = Keyword.get(opts, :whatsapp_opts, [])

    children = [
      {Kerf.Channels.WhatsApp, wa_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
