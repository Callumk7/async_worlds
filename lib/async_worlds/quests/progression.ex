defmodule AsyncWorlds.Quests.Progression do
  use Ecto.Schema

  schema "quest_progressions" do
    field :campaign_id, :id
    field :character_id, :id
    field :revision_id, :id
    field :node_id, :string
    field :status, Ecto.Enum, values: [:active, :completed, :ended]
  end
end
