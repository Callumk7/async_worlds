defmodule AsyncWorlds.Repo.Migrations.CreateQuestRolls do
  use Ecto.Migration

  def change do
    create table(:quest_rolls) do
      add :snapshot_id, references(:tick_snapshots, on_delete: :restrict), null: false
      add :identity, :text, null: false
      add :input, :map, null: false
      add :die_index, :integer, null: false
      add :value, :integer, null: false
    end

    create unique_index(:quest_rolls, [:snapshot_id, :identity])
    create constraint(:quest_rolls, :d6_value, check: "value BETWEEN 1 AND 6")
    create constraint(:quest_rolls, :die_index_range, check: "die_index BETWEEN 0 AND 2")

    execute """
            CREATE FUNCTION protect_quest_rolls() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'quest dice are immutable';
            END;
            $$;
            """,
            "DROP FUNCTION protect_quest_rolls()"

    execute "CREATE TRIGGER immutable_quest_rolls BEFORE UPDATE OR DELETE ON quest_rolls FOR EACH ROW EXECUTE FUNCTION protect_quest_rolls()",
            "DROP TRIGGER immutable_quest_rolls ON quest_rolls"
  end
end
