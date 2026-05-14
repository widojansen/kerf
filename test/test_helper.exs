# Detect whether the full application was started (i.e. NOT --no-start).
# The Dashboard Endpoint is only registered by the full app supervisor;
# if it is already alive, we know the full stack is up and :integration
# tests can run. Otherwise we exclude them.
integration_excluded = is_nil(Process.whereis(Kerf.Dashboard.Endpoint))

# :vllm tests require a real vLLM endpoint reachable at config'd VLLM_URL.
# Run them explicitly via `mix test --only vllm` or `mix test --include vllm`.
excluded =
  if integration_excluded,
    do: [:docker, :integration, :vllm],
    else: [:docker, :vllm]

ExUnit.start(exclude: excluded)

# ---------------------------------------------------------------------------
# Repo: start and put in sandbox mode (safe with --no-start)
# ---------------------------------------------------------------------------
repo_config = Application.get_env(:kerf, Kerf.Repo, [])

case Process.whereis(Kerf.Repo) do
  nil -> {:ok, _} = Kerf.Repo.start_link(repo_config)
  _pid -> :ok
end

Ecto.Adapters.SQL.Sandbox.mode(Kerf.Repo, :manual)
