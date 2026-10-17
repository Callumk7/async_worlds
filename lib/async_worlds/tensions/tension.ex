defmodule AsyncWorlds.Tensions.Tension do
  @moduledoc "A private DM-owned situation, not a location or quest. Resolution is publication-only (ENG-91)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "tensions" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:ongoing, :resolved], default: :ongoing
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(tension, attrs) do
    tension
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
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
