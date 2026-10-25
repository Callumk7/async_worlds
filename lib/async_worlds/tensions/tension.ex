defmodule AsyncWorlds.Tensions.Tension do
  @moduledoc "A DM-owned unsettled situation, private by default. Public audience explicitly releases its prose; resolution is publication-only."
  use Ecto.Schema
  import Ecto.Changeset

  schema "tensions" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    field :name, :string
    field :description, :string
    field :audience, Ecto.Enum, values: [:dm, :public], default: :dm
    field :status, Ecto.Enum, values: [:ongoing, :resolved], default: :ongoing
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(tension, attrs) do
    tension
    |> cast(attrs, [:name, :description, :audience])
    |> validate_required([:name, :audience])
    |> validate_text(:name, 200)
    |> validate_text(:description, 8000)
  end

  def validate_text(changeset, field, max) do
    validate_change(changeset, field, fn field, text ->
      if String.valid?(text) and not String.contains?(text, <<0>>) and byte_size(text) <= max,
        do: [],
        else: [{field, "must be valid UTF-8 without NUL, at most #{max} bytes"}]
    end)
  end
end
