defmodule AsyncWorlds.Discord.DebugSession do
  @moduledoc "Persisted Discord-only persona for the current campaign DM."
  use Ecto.Schema

  schema "discord_debug_sessions" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    belongs_to :character, AsyncWorlds.Characters.Character
    field :dm_user_id, :string
    field :guild_id, :string
    field :public_channel_id, :string
    field :enabled, :boolean, default: false
    field :role, Ecto.Enum, values: [:dm, :player], default: :dm
    field :copy_messages, :boolean, default: false
    field :generation, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
