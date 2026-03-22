defmodule ExClaw.Repo do
  use Ecto.Repo,
    otp_app: :exclaw,
    adapter: Ecto.Adapters.Postgres
end
