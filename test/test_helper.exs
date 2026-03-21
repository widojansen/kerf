# Detect whether the full application was started (i.e. NOT --no-start).
# The Dashboard Endpoint is only registered by the full app supervisor;
# if it is already alive, we know the full stack is up and :integration
# tests can run. Otherwise we exclude them.
integration_excluded = is_nil(Process.whereis(ExClaw.Dashboard.Endpoint))

excluded = if integration_excluded, do: [:docker, :integration], else: [:docker]

ExUnit.start(exclude: excluded)

# ---------------------------------------------------------------------------
# Repo: start and put in sandbox mode (safe with --no-start)
# ---------------------------------------------------------------------------
repo_config = Application.get_env(:exclaw, ExClaw.Repo, [])

case Process.whereis(ExClaw.Repo) do
  nil -> {:ok, _} = ExClaw.Repo.start_link(repo_config)
  _pid -> :ok
end

Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, :manual)
