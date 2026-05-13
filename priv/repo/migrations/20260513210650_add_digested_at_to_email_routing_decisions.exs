defmodule Kerf.Repo.Migrations.AddDigestedAtToEmailRoutingDecisions do
  use Ecto.Migration

  def change do
    alter table(:email_routing_decisions) do
      add :digested_at, :utc_datetime_usec, null: true
    end

    # Partial index for the digest worker's hot query:
    #   SELECT ... FROM email_routing_decisions
    #   WHERE digested_at IS NULL AND action_taken = 'telegram_digest'
    # The partial predicate keeps the index small (only undigested rows).
    create index(:email_routing_decisions, [:action_taken],
             where: "digested_at IS NULL",
             name: :email_routing_decisions_undigested_idx
           )
  end
end
