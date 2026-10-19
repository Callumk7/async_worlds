defmodule AsyncWorlds.Tensions.Discussion do
  use Ecto.Schema

  schema "tension_discussions" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    belongs_to :tension, AsyncWorlds.Tensions.Tension
    field :parent_id, :string
    field :guild_id, :string
    field :name, :string
    field :thread_id, :string
    field :status, :string, default: "pending"
    field :generation, :integer, default: 1
    field :recovery, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
