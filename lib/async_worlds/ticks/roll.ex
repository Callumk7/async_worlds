defmodule AsyncWorlds.Ticks.Roll do
  @moduledoc "Immutable individual quest die, associated with a frozen snapshot and submission."
  use Ecto.Schema

  schema "quest_rolls" do
    belongs_to :snapshot, AsyncWorlds.Ticks.Snapshot
    field :identity, :string
    field :input, :map
    field :die_index, :integer
    field :value, :integer
  end
end
