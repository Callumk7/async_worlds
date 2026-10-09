defmodule AsyncWorlds.Ticks.Tick do
  @moduledoc "A manually controlled campaign turn. Number advances on publication."
  use Ecto.Schema

  schema "ticks" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    field :number, :integer
    field :status, Ecto.Enum, values: [:open, :resolving, :in_review, :published], default: :open
    field :draft_revision, :integer, default: 0
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :reviewed_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
