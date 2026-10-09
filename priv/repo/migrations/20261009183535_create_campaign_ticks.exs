defmodule AsyncWorlds.Repo.Migrations.CreateCampaignTicks do
  use Ecto.Migration

  def change do
    create table(:ticks) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :status, :text, null: false, default: "open"
      add :draft_revision, :integer, null: false, default: 0
      add :opened_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :reviewed_at, :utc_datetime_usec
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ticks, [:campaign_id, :number])

    create unique_index(:ticks, [:campaign_id],
             name: :one_active_tick_per_campaign,
             where: "status != 'published'"
           )

    create constraint(:ticks, :valid_tick_status,
             check: "status IN ('open', 'resolving', 'in_review', 'published')"
           )

    create constraint(:ticks, :valid_tick_number, check: "number > 0")

    create constraint(:ticks, :valid_tick_lifecycle,
             check: """
             (status = 'open' AND closed_at IS NULL AND reviewed_at IS NULL AND published_at IS NULL AND draft_revision = 0)
             OR (status = 'resolving' AND closed_at IS NOT NULL AND reviewed_at IS NULL AND published_at IS NULL AND draft_revision = 0)
             OR (status = 'in_review' AND closed_at IS NOT NULL AND reviewed_at IS NOT NULL AND published_at IS NULL AND draft_revision > 0)
             OR (status = 'published' AND closed_at IS NOT NULL AND reviewed_at IS NOT NULL AND published_at IS NOT NULL AND draft_revision > 0)
             """
           )

    create table(:tick_snapshots) do
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :revision, :uuid, null: false
      add :schema_version, :integer, null: false, default: 1
      add :data, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tick_snapshots, [:tick_id])
    create unique_index(:tick_snapshots, [:revision])

    create table(:tick_drafts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false

      add :input_revision,
          references(:tick_snapshots, column: :revision, type: :uuid, on_delete: :delete_all),
          null: false

      add :revision, :integer, null: false
      add :payload, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tick_drafts, [:tick_id, :revision])
    create constraint(:tick_drafts, :positive_draft_revision, check: "revision > 0")

    execute(
      """
      CREATE FUNCTION reject_tick_input_update() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'tick snapshots and draft revisions are immutable';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION reject_tick_input_update()"
    )

    for table <- ["tick_snapshots", "tick_drafts"] do
      execute(
        """
        CREATE TRIGGER immutable_tick_record BEFORE UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION reject_tick_input_update()
        """,
        "DROP TRIGGER immutable_tick_record ON #{table}"
      )
    end
  end
end
