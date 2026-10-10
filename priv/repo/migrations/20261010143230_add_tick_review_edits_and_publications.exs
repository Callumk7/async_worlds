defmodule AsyncWorlds.Repo.Migrations.AddTickReviewEditsAndPublications do
  use Ecto.Migration

  def change do
    create table(:tick_review_edits) do
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :draft_id, references(:tick_drafts, type: :uuid), null: false
      add :previous_draft_id, references(:tick_drafts, type: :uuid), null: false
      add :actor_id, :text, null: false
      add :reason, :text, null: false
      add :operation, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tick_review_edits, [:draft_id])

    create table(:tick_publications) do
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :draft_id, references(:tick_drafts, type: :uuid), null: false
      add :payload, :map, null: false
      add :outputs, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tick_publications, [:tick_id])

    execute(
      """
      CREATE FUNCTION reject_tick_history_change() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'UPDATE' OR EXISTS (SELECT 1 FROM ticks WHERE id = OLD.tick_id) THEN
          RAISE EXCEPTION 'tick review edits and publications are immutable';
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION IF EXISTS reject_tick_history_change()"
    )

    for table <- ["tick_review_edits", "tick_publications"] do
      execute(
        """
        CREATE TRIGGER immutable_tick_record BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION reject_tick_history_change()
        """,
        "DROP TRIGGER immutable_tick_record ON #{table}"
      )
    end
  end
end
