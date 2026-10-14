defmodule AsyncWorlds.Repo.Migrations.CreateFactions do
  use Ecto.Migration

  def change do
    create table(:factions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create index(:factions, [:campaign_id])
  end
end
