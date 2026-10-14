defmodule AsyncWorlds.Ticks.Briefing do
  @moduledoc "Immutable opening narration and exact ordered outgoing chunks. Existing ticks are not backfilled."
  use Ecto.Schema

  schema "tick_briefings" do
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    field :narration, :string
    field :renderer_version, :integer
    field :input_version, :string
    field :public_channel_id, :string
    field :outputs, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
