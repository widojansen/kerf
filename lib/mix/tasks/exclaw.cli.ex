defmodule Mix.Tasks.Exclaw.Cli do
  @moduledoc """
  Starts the ExClaw CLI REPL.

      mix exclaw.cli

  Options are read from `config :exclaw, ExClaw.Channels.CLI`.
  """
  use Mix.Task

  @shortdoc "Start the ExClaw CLI assistant"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    ExClaw.Channels.CLI.start()
  end
end
