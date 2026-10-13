defmodule AsyncWorlds.Repo.Migrations.CreateQuestWorkingCopies do
  use Ecto.Migration

  def change do
    create table(:quest_working_copies) do
      add :campaign_id, references(:campaigns), null: false
      add :quest_id, :bigint
      add :base_revision_id, :bigint
      add :name, :text, null: false, default: ""
      add :content_id, :text, null: false, default: ""
      add :definition, :map, null: false
      add :source_definition, :map, null: false
      add :version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    execute "ALTER TABLE quest_working_copies ADD FOREIGN KEY (quest_id, campaign_id) REFERENCES quests(id, campaign_id)",
            "ALTER TABLE quest_working_copies DROP CONSTRAINT quest_working_copies_quest_id_campaign_id_fkey"

    execute "ALTER TABLE quest_working_copies ADD FOREIGN KEY (base_revision_id, campaign_id) REFERENCES quest_revisions(id, campaign_id)",
            "ALTER TABLE quest_working_copies DROP CONSTRAINT quest_working_copies_base_revision_id_campaign_id_fkey"

    create index(:quest_working_copies, [:campaign_id])
    create constraint(:quest_working_copies, :working_copy_version, check: "version > 0")
  end
end
