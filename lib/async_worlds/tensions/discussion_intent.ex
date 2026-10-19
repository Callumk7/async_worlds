defmodule AsyncWorlds.Tensions.DiscussionIntent do
  use Ecto.Schema

  schema "tension_discussion_intents" do
    belongs_to :discussion, AsyncWorlds.Tensions.Discussion
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    field :key, :string
    field :content, :string
    field :overview, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
