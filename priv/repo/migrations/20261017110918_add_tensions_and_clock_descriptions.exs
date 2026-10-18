defmodule AsyncWorlds.Repo.Migrations.AddTensionsAndClockDescriptions do
  use Ecto.Migration

  def change do
    create table(:tensions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :name, :string, size: 200, null: false
      add :description, :text
      add :status, :string, null: false, default: "ongoing"
      add :revision, :bigint, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create index(:tensions, [:campaign_id])
    create unique_index(:tensions, [:campaign_id, :id])

    create constraint(:tensions, :valid_tension_status,
             check: "status IN ('ongoing', 'resolved')"
           )

    alter table(:clocks) do
      add :tension_id, :bigint
      add :association_revision, :bigint, null: false, default: 0
      add :mode, :string, null: false, default: "countdown"
      add :influences, :text
      add :empty_description, :text
      add :full_description, :text
    end

    create index(:clocks, [:tension_id])
    create constraint(:clocks, :valid_clock_mode, check: "mode IN ('countdown', 'tug_of_war')")

    execute "ALTER TABLE clocks ADD CONSTRAINT clocks_tension_campaign_fk FOREIGN KEY (campaign_id, tension_id) REFERENCES tensions(campaign_id, id)",
            "ALTER TABLE clocks DROP CONSTRAINT clocks_tension_campaign_fk"
  end
end
