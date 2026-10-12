defmodule AsyncWorlds.Quests.Unlock do
  @moduledoc "Published quest availability, not an assignment."
  use Ecto.Schema

  schema "quest_unlocks" do
    field :campaign_id, :integer
    field :character_id, :integer
    field :quest_id, :integer
  end
end
