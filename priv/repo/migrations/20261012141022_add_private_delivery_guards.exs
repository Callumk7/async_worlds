defmodule AsyncWorlds.Repo.Migrations.AddPrivateDeliveryGuards do
  use Ecto.Migration

  def change do
    alter table(:discord_deliveries) do
      add :guard, :map, null: false, default: %{}
    end
  end
end
