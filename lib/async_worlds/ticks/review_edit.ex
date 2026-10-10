defmodule AsyncWorlds.Ticks.ReviewEdit do
  @moduledoc "Append-only DM review operation connecting two immutable revisions."
  use Ecto.Schema

  schema "tick_review_edits" do
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    belongs_to :draft, AsyncWorlds.Ticks.Draft, type: Ecto.UUID
    belongs_to :previous_draft, AsyncWorlds.Ticks.Draft, type: Ecto.UUID
    field :actor_id, :string
    field :reason, :string
    field :operation, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
