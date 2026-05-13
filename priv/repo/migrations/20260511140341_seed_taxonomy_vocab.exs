defmodule Kerf.Repo.Migrations.SeedTaxonomyVocab do
  use Ecto.Migration

  @topics ~w(kerf legal financial automotive agency_partner family infrastructure ai_industry dev_tools)
  @actions ~w(reply_needed review schedule pay file delete_candidate fyi)

  def up do
    seed("email_topic_taxonomy", @topics)
    seed("email_action_taxonomy", @actions)
  end

  def down do
    execute "DELETE FROM email_topic_taxonomy WHERE proposed_by = 'seed'"
    execute "DELETE FROM email_action_taxonomy WHERE proposed_by = 'seed'"
  end

  defp seed(table, values) do
    Enum.each(values, fn value ->
      execute """
      INSERT INTO #{table} (value, accepted, proposed_by, proposed_at, accepted_at, usage_count, inserted_at, updated_at)
      VALUES ('#{value}', TRUE, 'seed', now(), now(), 0, now(), now())
      """
    end)
  end
end
