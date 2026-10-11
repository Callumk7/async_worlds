defmodule AsyncWorlds.Quests.Quest do
  use Ecto.Schema

  schema "quests" do
    field :campaign_id, :id
    field :content_id, :string
    field :name, :string
  end
end
