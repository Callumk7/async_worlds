defmodule AsyncWorlds.Repo.Migrations.AddDiscordDebugSessionsAndOptionalCharacterOwners do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      modify :discord_user_id, :string, null: true, from: {:string, null: false}
    end

    create table(:discord_debug_sessions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :dm_user_id, :string, null: false
      add :guild_id, :string, null: false
      add :public_channel_id, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :role, :string, null: false, default: "dm"
      add :character_id, references(:characters, on_delete: :nilify_all)
      add :copy_messages, :boolean, null: false, default: false
      add :generation, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:discord_debug_sessions, [:campaign_id])
    create constraint(:discord_debug_sessions, :debug_role, check: "role IN ('dm', 'player')")
    create constraint(:discord_debug_sessions, :debug_generation, check: "generation >= 0")
  end
end
