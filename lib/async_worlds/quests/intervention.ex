defmodule AsyncWorlds.Quests.Intervention do
  @moduledoc "Immutable DM intervention history, committed with progression and invalidation. DM-only."
  use Ecto.Schema

  schema "quest_interventions" do
    field :campaign_id, :id
    field :character_id, :id
    field :tick_id, :id
    field :actor_id, :string
    field :operation, :string
    field :reason, :string
    field :before, :map
    field :after, :map
    field :invalidated_submissions, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
