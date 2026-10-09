defmodule AsyncWorlds.Campaigns.Campaign do
  @moduledoc "The persisted boundary for one Discord guild's campaign."
  use Ecto.Schema
  import Ecto.Changeset

  alias AsyncWorlds.Discord.Snowflake

  schema "campaigns" do
    field :discord_guild_id, Snowflake
    field :dm_user_id, Snowflake
    field :public_channel_id, Snowflake
    field :current_tick_number, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc "Validates setup configuration. Tick progression cannot be changed by setup."
  def setup_changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:discord_guild_id, :dm_user_id, :public_channel_id],
      message: fn _, _ -> "must be a positive unsigned 64-bit Discord ID" end
    )
    |> validate_required([:discord_guild_id, :dm_user_id, :public_channel_id])
    |> unique_constraint(:discord_guild_id)
  end
end
