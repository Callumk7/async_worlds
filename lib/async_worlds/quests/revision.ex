defmodule AsyncWorlds.Quests.Revision do
  use Ecto.Schema

  schema "quest_revisions" do
    field :campaign_id, :id
    field :quest_id, :id
    field :number, :integer
    field :definition, :map
  end
end
