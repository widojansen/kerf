defmodule Kerf.Repo do
  use Ecto.Repo,
    otp_app: :kerf,
    adapter: Ecto.Adapters.Postgres
end
