defmodule ExClaw.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def change do
    create table(:memories) do
      add :group_id, :string, null: false
      add :key, :string, null: false
      add :value, :text, null: false
      add :source, :string

      timestamps()
    end

    create unique_index(:memories, [:group_id, :key])
    create index(:memories, [:group_id])
  end
end
