defmodule ExClaw.Repo.Migrations.CreateKbFeedback do
  use Ecto.Migration

  def change do
    create table(:kb_feedback, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :document_id, references(:kb_documents, type: :uuid, on_delete: :nilify_all)
      add :feedback_type, :string, null: false, size: 50
      add :decision, :string, null: false, size: 50
      add :context, :map, default: %{}
      add :source, :string, size: 50, default: "telegram"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:kb_feedback, [:document_id])
    create index(:kb_feedback, [:feedback_type])
    create index(:kb_feedback, [:inserted_at])
  end
end
