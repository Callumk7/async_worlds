defmodule AsyncWorlds.Repo.Migrations.CreateFactionMemberships do
  use Ecto.Migration

  def change do
    create unique_index(:factions, [:id, :campaign_id])

    create table(:faction_memberships) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false

      add :character_id,
          references(:characters, with: [campaign_id: :campaign_id], on_delete: :nothing),
          null: false

      add :faction_id,
          references(:factions, with: [campaign_id: :campaign_id], on_delete: :nothing),
          null: false

      add :role, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:faction_memberships, [:character_id, :faction_id])
    create index(:faction_memberships, [:campaign_id, :faction_id, :id])
    create index(:faction_memberships, [:campaign_id, :character_id, :id])
  end
end
