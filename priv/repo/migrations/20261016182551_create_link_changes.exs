defmodule AsyncWorlds.Repo.Migrations.CreateLinkChanges do
  use Ecto.Migration

  def change do
    create table(:link_changes) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      # The next tick need not exist yet. (campaign_id, tick_number) is the
      # permanent association; opening a tick never rewrites these records.
      add :tick_number, :integer, null: false
      add :kind, :string, null: false
      # Historical identities, deliberately not FKs to live links/entities.
      add :link_id, :bigint
      add :entity_refs, :map, null: false
      add :before, :map
      add :after, :map
      add :actor_id, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:link_changes, [:campaign_id, :tick_number, :id])
    create index(:link_changes, [:campaign_id, :id])
    create index(:link_changes, [:entity_refs], using: :gin)

    create constraint(:link_changes, :link_change_tick_positive, check: "tick_number > 0")

    create constraint(:link_changes, :link_change_kind_valid,
             check: "kind IN ('faction_membership', 'location_containment')"
           )

    create constraint(:link_changes, :link_change_refs_object,
             check: "jsonb_typeof(entity_refs) = 'object' AND entity_refs <> '{}'::jsonb"
           )

    create constraint(:link_changes, :link_change_state_valid,
             check:
               "(before IS NULL OR jsonb_typeof(before) = 'object') AND " <>
                 "(after IS NULL OR jsonb_typeof(after) = 'object') AND " <>
                 "before IS DISTINCT FROM after"
           )

    execute(
      """
      CREATE FUNCTION reject_link_history_change() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'UPDATE' OR EXISTS (SELECT 1 FROM campaigns WHERE id = OLD.campaign_id) THEN
          RAISE EXCEPTION 'link changes are immutable';
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION IF EXISTS reject_link_history_change()"
    )

    execute(
      """
      CREATE TRIGGER immutable_link_change BEFORE UPDATE OR DELETE ON link_changes
      FOR EACH ROW EXECUTE FUNCTION reject_link_history_change()
      """,
      "DROP TRIGGER immutable_link_change ON link_changes"
    )
  end
end
