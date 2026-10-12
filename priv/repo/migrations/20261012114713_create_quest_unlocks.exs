defmodule AsyncWorlds.Repo.Migrations.CreateQuestUnlocks do
  use Ecto.Migration

  def change do
    create table(:quest_unlocks) do
      add :campaign_id, references(:campaigns), null: false
      add :character_id, :bigint, null: false
      add :quest_id, :bigint, null: false
    end

    execute "ALTER TABLE quest_unlocks ADD FOREIGN KEY (character_id, campaign_id) REFERENCES characters(id, campaign_id)",
            "SELECT 1"

    execute "ALTER TABLE quest_unlocks ADD FOREIGN KEY (quest_id, campaign_id) REFERENCES quests(id, campaign_id)",
            "SELECT 1"

    create unique_index(:quest_unlocks, [:character_id, :quest_id])

    for table <- ~w(tick_snapshots tick_drafts) do
      execute "CREATE TRIGGER immutable_tick_delete BEFORE DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION reject_tick_history_change()",
              "DROP TRIGGER IF EXISTS immutable_tick_delete ON #{table}"
    end
  end
end
