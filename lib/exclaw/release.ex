defmodule ExClaw.Release do
  @moduledoc """
  Release tasks (migrations) callable without Mix.

  Usage from release binary:

      bin/exclaw eval "ExClaw.Release.migrate()"
      bin/exclaw eval "ExClaw.Release.rollback(ExClaw.Repo, 20260219175156)"
  """

  @app :exclaw

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
