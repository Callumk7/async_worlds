defmodule AsyncWorlds.Quests.Submission do
  @moduledoc "One editable choice per character/tick. Never exposed as a player struct."
  use Ecto.Schema

  schema "quest_submissions" do
    field :campaign_id, :id
    field :tick_id, :id
    field :character_id, :id
    field :progression_id, :id
    field :revision_id, :id
    field :node_id, :string
    field :position_version, :integer
    field :choice_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
