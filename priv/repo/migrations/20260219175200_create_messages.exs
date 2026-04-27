defmodule Kerf.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :group_id, :string, null: false
      add :role, :string, null: false
      add :content, :text
      add :tool_name, :string
      add :tool_input, :text

      timestamps()
    end

    create index(:messages, [:group_id, :inserted_at])
  end
end
