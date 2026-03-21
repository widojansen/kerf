defmodule ExClaw.DataCase do
  @moduledoc """
  Test case template for tests that require database access.
  Safe to use with --no-start: starts ExClaw.Repo automatically.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ExClaw.Repo
      import ExClaw.DataCase, only: [allow_repo: 1]
    end
  end

  setup _tags do
    ExClaw.DataCase.setup_sandbox()
  end

  def setup_sandbox do
    ensure_repo_started()
    Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ExClaw.Repo)
    :ok
  end

  def allow_repo(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(ExClaw.Repo, self(), pid)
  end

  defp ensure_repo_started do
    case Process.whereis(ExClaw.Repo) do
      nil ->
        config = Application.get_env(:exclaw, ExClaw.Repo, [])
        {:ok, _} = ExClaw.Repo.start_link(config)
      _pid -> :ok
    end
  end
end
