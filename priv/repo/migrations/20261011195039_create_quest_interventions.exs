defmodule AsyncWorlds.Repo.Migrations.CreateQuestInterventions do
  use Ecto.Migration

  def change do
    create table(:quest_interventions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :character_id, :bigint, null: false
      add :tick_id, :bigint
      add :actor_id, :text, null: false
      add :operation, :text, null: false
      add :reason, :text, null: false
      add :before, :map
      add :after, :map, null: false
      add :invalidated_submissions, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute "ALTER TABLE quest_interventions ADD FOREIGN KEY (character_id, campaign_id) REFERENCES characters(id, campaign_id) ON DELETE CASCADE",
            "ALTER TABLE quest_interventions DROP CONSTRAINT quest_interventions_character_id_campaign_id_fkey"

    execute "ALTER TABLE quest_interventions ADD FOREIGN KEY (tick_id, campaign_id) REFERENCES ticks(id, campaign_id) ON DELETE CASCADE",
            "ALTER TABLE quest_interventions DROP CONSTRAINT quest_interventions_tick_id_campaign_id_fkey"

    create index(:quest_interventions, [:campaign_id, :character_id, :id])

    create constraint(:quest_interventions, :quest_intervention_valid,
             check:
               "operation IN ('assign', 'swap', 'end', 'move') AND length(btrim(reason)) BETWEEN 1 AND 2000 AND invalidated_submissions >= 0"
           )

    execute """
            CREATE FUNCTION reject_quest_intervention_change() RETURNS trigger AS $$
            BEGIN
              IF TG_OP = 'UPDATE' OR EXISTS (SELECT 1 FROM campaigns WHERE id = OLD.campaign_id) THEN
                RAISE EXCEPTION 'quest interventions are immutable';
              END IF;
              RETURN OLD;
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION IF EXISTS reject_quest_intervention_change()"

    execute """
            CREATE TRIGGER immutable_quest_intervention BEFORE UPDATE OR DELETE ON quest_interventions
            FOR EACH ROW EXECUTE FUNCTION reject_quest_intervention_change()
            """,
            "DROP TRIGGER immutable_quest_intervention ON quest_interventions"
  end
end
