defmodule AsyncWorlds.Repo.Migrations.AddLocationHierarchy do
  use Ecto.Migration

  def change do
    create unique_index(:locations, [:id, :campaign_id])

    alter table(:locations) do
      add :kind, :text

      add :parent_id,
          references(:locations,
            with: [campaign_id: :campaign_id],
            match: :simple,
            on_delete: :nothing
          )
    end

    create index(:locations, [:campaign_id, :parent_id, :id])

    create constraint(:locations, :locations_not_self_parent,
             check: "parent_id IS NULL OR parent_id <> id"
           )
  end
end
