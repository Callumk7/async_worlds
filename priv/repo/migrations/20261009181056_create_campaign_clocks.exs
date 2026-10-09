defmodule AsyncWorlds.Repo.Migrations.CreateCampaignClocks do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :clock_mutations_locked, :boolean, null: false, default: false
    end

    create table(:clocks) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :segments, :integer, null: false
      add :filled, :integer, null: false, default: 0
      add :visibility, :text, null: false, default: "public"
      add :background_rate, :integer, null: false, default: 0
      add :paused, :boolean, null: false, default: false
      add :completed, :boolean, null: false, default: false
      add :racing_group, :uuid
      add :triggers, {:array, :map}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create index(:clocks, [:campaign_id])
    create constraint(:clocks, :valid_segments, check: "segments IN (4, 6, 8)")
    create constraint(:clocks, :valid_fill, check: "filled >= 0 AND filled <= segments")

    create constraint(:clocks, :valid_visibility,
             check: "visibility IN ('public', 'known', 'hidden')"
           )

    create table(:clock_audits) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :clock_id, references(:clocks, on_delete: :delete_all), null: false
      add :source, :text, null: false
      add :operation, :text, null: false
      add :before, :map, null: false
      add :after, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:clock_audits, [:campaign_id, :clock_id])
  end
end
