defmodule AsyncWorlds.Tensions.Commitment do
  use Ecto.Schema

  schema "tension_commitments" do
    field :campaign_id, :id
    field :tick_id, :id
    field :tension_id, :id
    field :character_id, :id
    field :version, :integer, default: 0
    field :state, Ecto.Enum, values: [:unresolved, :confirmed, :withdrawn]
    field :intention, :string
    field :approach, :string
    field :ready, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end
end
