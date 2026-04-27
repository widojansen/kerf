defmodule Kerf.Repo.Migrations.CreateKbInterests do
  use Ecto.Migration

  def change do
    create table(:kb_interests, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :topic, :string, null: false, size: 255
      add :keywords, {:array, :string}, default: []
      add :weight, :float, null: false, default: 1.0
      add :embedding, :vector, size: 1024
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:kb_interests, [:topic])
  end
end
