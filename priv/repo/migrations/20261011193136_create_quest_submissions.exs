defmodule AsyncWorlds.Repo.Migrations.CreateQuestSubmissions do
  use Ecto.Migration

  def change do
    alter table(:quest_progressions) do
      add :position_version, :bigint, null: false, default: 1
    end

    create unique_index(:quest_progressions, [:id, :campaign_id])
    create unique_index(:ticks, [:id, :campaign_id])

    create table(:quest_submissions) do
      add :campaign_id, references(:campaigns), null: false
      add :tick_id, :bigint, null: false
      add :character_id, :bigint, null: false
      add :progression_id, :bigint, null: false
      add :revision_id, :bigint, null: false
      add :node_id, :text, null: false
      add :position_version, :bigint, null: false
      add :choice_id, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    for {column, table} <- [
          tick_id: "ticks",
          character_id: "characters",
          progression_id: "quest_progressions",
          revision_id: "quest_revisions"
        ] do
      execute "ALTER TABLE quest_submissions ADD FOREIGN KEY (#{column}, campaign_id) REFERENCES #{table}(id, campaign_id)",
              "ALTER TABLE quest_submissions DROP CONSTRAINT quest_submissions_#{column}_campaign_id_fkey"
    end

    execute "ALTER TABLE quest_submissions ADD FOREIGN KEY (revision_id, node_id) REFERENCES quest_revision_nodes(revision_id, node_id)",
            "ALTER TABLE quest_submissions DROP CONSTRAINT quest_submissions_revision_id_node_id_fkey"

    create unique_index(:quest_submissions, [:tick_id, :character_id])
  end
end
