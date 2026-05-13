defmodule Kerf.Repo.Migrations.CreateEmailTriage do
  use Ecto.Migration

  def change do
    create table(:email_triage, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :document_id, references(:kb_documents, type: :uuid, on_delete: :delete_all), null: false

      # Stage 1: deterministic (FastClassifier) or LLM fallback
      add :category, :string
      add :sender_type, :string
      add :classifier_source, :string, null: false
      add :confidence, :float

      # Stage 2: async LLM enrichment
      add :urgency, :string
      add :action, :string
      add :topic, {:array, :string}, default: []
      add :summary, :text

      # Status & versioning
      add :triage_status, :string, null: false, default: "pending"
      add :triage_error, :text
      add :enriched_at, :utc_datetime_usec
      add :classified_at, :utc_datetime_usec
      add :enrichment_version, :integer, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_triage, [:document_id])
    create index(:email_triage, [:triage_status])
    create index(:email_triage, [:category])
    create index(:email_triage, [:sender_type])
    create index(:email_triage, [:urgency])
    create index(:email_triage, [:action])
    create index(:email_triage, [:topic], using: :gin)
    create index(:email_triage, [:enriched_at])
  end
end
