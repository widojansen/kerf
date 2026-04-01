defmodule ExClaw.Repo.Migrations.CreateEmailSenders do
  use Ecto.Migration

  def change do
    create table(:email_senders, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :string, null: false, size: 500
      add :name, :string, size: 255
      add :domain, :string, size: 255
      add :priority_score, :float, null: false, default: 0.0
      add :is_priority, :boolean, null: false, default: false
      add :total_emails, :integer, null: false, default: 0
      add :total_interactions, :integer, null: false, default: 0
      add :last_email_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_senders, [:email])
    create index(:email_senders, [:domain])

    create index(:email_senders, [:is_priority],
      where: "is_priority = TRUE",
      name: :email_senders_is_priority_true_index
    )
  end
end
