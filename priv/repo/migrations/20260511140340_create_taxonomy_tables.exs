defmodule Kerf.Repo.Migrations.CreateTaxonomyTables do
  use Ecto.Migration

  def change do
    for dim <- [:topic, :action] do
      create table("email_#{dim}_taxonomy", primary_key: false) do
        add :value, :string, primary_key: true
        add :accepted, :boolean, default: false, null: false
        add :proposed_by, :string
        add :proposed_at, :utc_datetime_usec, default: fragment("now()")
        add :accepted_at, :utc_datetime_usec
        add :usage_count, :integer, default: 0, null: false
        add :description, :text
        timestamps(type: :utc_datetime_usec)
      end

      create index("email_#{dim}_taxonomy", [:accepted])
    end
  end
end
