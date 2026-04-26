defmodule Mix.Tasks.Kerf.Cli do
  @moduledoc """
  Starts the Kerf CLI REPL.

      mix exclaw.cli

  Options are read from `config :kerf, Kerf.Channels.CLI`.
  """
  use Mix.Task

  @shortdoc "Start the Kerf CLI assistant"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Kerf.Channels.CLI.start()
  end
end
