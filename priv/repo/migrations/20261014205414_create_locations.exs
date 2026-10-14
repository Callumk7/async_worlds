defmodule AsyncWorlds.Repo.Migrations.CreateLocations do
  use Ecto.Migration

  def change do
    create table(:locations) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create index(:locations, [:campaign_id])
  end
end
