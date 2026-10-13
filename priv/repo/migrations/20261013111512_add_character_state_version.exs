defmodule AsyncWorlds.Repo.Migrations.AddCharacterStateVersion do
  use Ecto.Migration

  def up do
    alter table(:characters) do
      add :state_version, :bigint, null: false, default: 1
    end

    # Includes approved tick publication and other non-editor writers.
    execute """
    CREATE FUNCTION advance_character_state_version() RETURNS trigger AS $$
    BEGIN
      NEW.state_version := OLD.state_version + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER character_state_version BEFORE UPDATE ON characters
    FOR EACH ROW EXECUTE FUNCTION advance_character_state_version();
    """
  end

  def down do
    execute "DROP TRIGGER character_state_version ON characters"
    execute "DROP FUNCTION advance_character_state_version()"
    alter table(:characters), do: remove(:state_version)
  end
end
