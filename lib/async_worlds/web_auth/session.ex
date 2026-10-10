defmodule AsyncWorlds.WebAuth.Session do
  @moduledoc false
  use Ecto.Schema

  alias AsyncWorlds.Discord.Snowflake

  schema "web_sessions" do
    field :token_hash, :binary
    field :discord_user_id, Snowflake
    field :discord_guild_id, Snowflake
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
