defmodule AsyncWorlds.Repo.Migrations.CreateQuestDomain do
  use Ecto.Migration

  def up do
    create unique_index(:characters, [:id, :campaign_id])

    create table(:quests) do
      add :campaign_id, references(:campaigns), null: false
      add :content_id, :string, null: false
      add :name, :string, null: false
    end

    create unique_index(:quests, [:campaign_id, :content_id])
    create unique_index(:quests, [:id, :campaign_id])

    create constraint(:quests, :quest_content_id_valid,
             check: "length(content_id) BETWEEN 1 AND 100"
           )

    create table(:quest_revisions) do
      add :campaign_id, :bigint, null: false
      add :quest_id, :bigint, null: false
      add :number, :integer, null: false
      add :definition, :map, null: false
    end

    execute "ALTER TABLE quest_revisions ADD FOREIGN KEY (quest_id, campaign_id) REFERENCES quests(id, campaign_id)"

    create unique_index(:quest_revisions, [:quest_id, :number])
    create unique_index(:quest_revisions, [:id, :campaign_id])

    create constraint(:quest_revisions, :quest_revision_valid,
             check: "number > 0 AND jsonb_typeof(definition) = 'object'"
           )

    create table(:quest_revision_nodes, primary_key: false) do
      add :revision_id, references(:quest_revisions), null: false, primary_key: true
      add :node_id, :string, null: false, primary_key: true
    end

    create table(:quest_progressions) do
      add :campaign_id, :bigint, null: false
      add :character_id, :bigint, null: false
      add :revision_id, :bigint, null: false
      add :node_id, :string, null: false
      add :status, :string, null: false
    end

    execute "ALTER TABLE quest_progressions ADD FOREIGN KEY (character_id, campaign_id) REFERENCES characters(id, campaign_id)"

    execute "ALTER TABLE quest_progressions ADD FOREIGN KEY (revision_id, campaign_id) REFERENCES quest_revisions(id, campaign_id)"

    execute "ALTER TABLE quest_progressions ADD FOREIGN KEY (revision_id, node_id) REFERENCES quest_revision_nodes(revision_id, node_id)"

    create constraint(:quest_progressions, :quest_status_valid,
             check: "status IN ('active', 'completed', 'ended')"
           )

    create unique_index(:quest_progressions, [:character_id],
             where: "status = 'active'",
             name: :one_active_quest_per_character
           )

    execute """
    CREATE FUNCTION reject_quest_revision_change() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'quest revisions are immutable'; END;
    $$ LANGUAGE plpgsql
    """

    for table <- ~w(quest_revisions quest_revision_nodes) do
      execute "CREATE TRIGGER immutable_#{table} BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION reject_quest_revision_change()"
    end
  end

  def down do
    drop table(:quest_progressions)
    drop table(:quest_revision_nodes)
    drop table(:quest_revisions)
    execute "DROP FUNCTION reject_quest_revision_change()"
    drop table(:quests)
    drop index(:characters, [:id, :campaign_id])
  end
end
