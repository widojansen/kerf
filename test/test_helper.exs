ExUnit.start(exclude: [:docker])

if Process.whereis(ExClaw.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(ExClaw.Repo, :manual)
end
