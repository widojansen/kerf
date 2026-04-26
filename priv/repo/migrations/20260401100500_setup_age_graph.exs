defmodule Kerf.Repo.Migrations.SetupAgeGraph do
  use Ecto.Migration

  def up do
    execute("LOAD 'age'")
    execute("SET search_path = ag_catalog, \"$user\", public")

    # Create graph only if it doesn't already exist
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'exclaw_kg'
      ) THEN
        PERFORM ag_catalog.create_graph('exclaw_kg');
      END IF;
    END $$
    """)

    # Restore default search_path so subsequent migrations create tables in public
    execute("SET search_path = \"$user\", public")
  end

  def down do
    execute("LOAD 'age'")
    execute("SET search_path = ag_catalog, \"$user\", public")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'exclaw_kg'
      ) THEN
        PERFORM ag_catalog.drop_graph('exclaw_kg', true);
      END IF;
    END $$
    """)

    execute("SET search_path = \"$user\", public")
  end
end
