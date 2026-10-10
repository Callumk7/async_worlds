defmodule AsyncWorlds.Ticks.Publication do
  @moduledoc "Immutable approved resolution and exact outgoing content; not a rollback facility."
  use Ecto.Schema

  schema "tick_publications" do
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    belongs_to :draft, AsyncWorlds.Ticks.Draft, type: Ecto.UUID
    field :payload, :map
    field :outputs, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
