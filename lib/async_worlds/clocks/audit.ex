defmodule AsyncWorlds.Clocks.Audit do
  @moduledoc "Source-labelled before/after record, written atomically with clock management."
  use Ecto.Schema

  schema "clock_audits" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    belongs_to :clock, AsyncWorlds.Clocks.Clock
    field :source, :string
    field :operation, :string
    field :before, :map
    field :after, :map
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
