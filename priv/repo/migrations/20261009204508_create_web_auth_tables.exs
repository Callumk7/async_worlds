defmodule AsyncWorlds.Repo.Migrations.CreateWebAuthTables do
  use Ecto.Migration

  def change do
    create table(:oauth_states) do
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_states, [:token_hash])
    create index(:oauth_states, [:expires_at])

    create table(:web_sessions) do
      add :token_hash, :binary, null: false
      add :discord_user_id, :string, null: false
      add :discord_guild_id, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:web_sessions, [:token_hash])
    create index(:web_sessions, [:discord_user_id])
    create index(:web_sessions, [:expires_at])
  end
end
