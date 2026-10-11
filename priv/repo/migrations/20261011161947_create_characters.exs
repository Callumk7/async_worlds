defmodule AsyncWorlds.Repo.Migrations.CreateCharacters do
  use Ecto.Migration

  def change do
    create table(:characters) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :discord_user_id, :string, null: false
      add :name, :string, null: false
      add :flags, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:characters, [:campaign_id, :discord_user_id])

    create constraint(:characters, :characters_discord_user_id_valid,
             check:
               "discord_user_id ~ '^[1-9][0-9]{0,19}$' AND length(discord_user_id) <= 20 AND discord_user_id::numeric <= 18446744073709551615"
           )

    create constraint(:characters, :characters_flags_object,
             check: "jsonb_typeof(flags) = 'object'"
           )
  end
end
