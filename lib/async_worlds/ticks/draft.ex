defmodule AsyncWorlds.Ticks.Draft do
  @moduledoc "Immutable DM-only resolution/review revision tied to frozen inputs."
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "tick_drafts" do
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    field :input_revision, Ecto.UUID
    field :revision, :integer
    field :payload, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
