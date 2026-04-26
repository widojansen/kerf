defmodule Kerf.Repo.Migrations.AddPgExtensions do
  use Ecto.Migration

  def change do
    # Only run on PostgreSQL (skip for SQLite test env)
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"
      execute "CREATE EXTENSION IF NOT EXISTS age", "DROP EXTENSION IF EXISTS age"
      execute "SET search_path = ag_catalog, public", ""
      # AGE needs ag_catalog in search_path during LOAD, but restore default
      # so subsequent migrations create tables in public schema
      execute "SET search_path = \"$user\", public", ""
    end
  end
end
