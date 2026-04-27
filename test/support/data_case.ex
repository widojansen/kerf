defmodule Kerf.DataCase do
  @moduledoc """
  Test case template for tests that require database access.
  Safe to use with --no-start: starts Kerf.Repo automatically.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Kerf.Repo
      import Kerf.DataCase, only: [allow_repo: 1]
    end
  end

  setup _tags do
    Kerf.DataCase.setup_sandbox()
  end

  def setup_sandbox do
    ensure_repo_started()
    Ecto.Adapters.SQL.Sandbox.mode(Kerf.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kerf.Repo)
    :ok
  end

  def allow_repo(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Kerf.Repo, self(), pid)
  end

  defp ensure_repo_started do
    case Process.whereis(Kerf.Repo) do
      nil ->
        config = Application.get_env(:kerf, Kerf.Repo, [])
        {:ok, _} = Kerf.Repo.start_link(config)
      _pid -> :ok
    end
  end
end
