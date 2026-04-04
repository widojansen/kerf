defmodule ExClaw.Repo.Migrations.AddClassificationToEmailSenders do
  use Ecto.Migration

  def change do
    alter table(:email_senders) do
      add :classification_override, :string, size: 50
      add :priority_override, :integer
      add :match_pattern, :string, size: 500
    end

    create index(:email_senders, [:classification_override])
  end
end
