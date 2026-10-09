defmodule AsyncWorlds.Ticks.Snapshot do
  @moduledoc "Immutable, versioned world inputs captured exactly once at close. DM-only."
  use Ecto.Schema

  schema "tick_snapshots" do
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    field :revision, Ecto.UUID
    field :schema_version, :integer, default: 1
    field :data, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
