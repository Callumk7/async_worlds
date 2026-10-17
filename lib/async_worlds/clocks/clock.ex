defmodule AsyncWorlds.Clocks.Clock do
  @moduledoc "Campaign-owned clock. Completion is latched explicitly in the trigger phase."
  use Ecto.Schema
  import Ecto.Changeset
  alias AsyncWorlds.Clocks.Trigger

  schema "clocks" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    belongs_to :tension, AsyncWorlds.Tensions.Tension
    field :association_revision, :integer, default: 0
    field :mode, Ecto.Enum, values: [:countdown, :tug_of_war], default: :countdown
    field :influences, :string
    field :empty_description, :string
    field :full_description, :string
    field :name, :string
    field :segments, :integer
    field :filled, :integer, default: 0
    field :visibility, Ecto.Enum, values: [:public, :known, :hidden], default: :public
    field :background_rate, :integer, default: 0
    field :paused, :boolean, default: false
    field :completed, :boolean, default: false
    field :racing_group, Ecto.UUID
    embeds_many :triggers, Trigger, on_replace: :delete
    timestamps(type: :utc_datetime)
  end

  def changeset(clock, attrs) do
    clock
    |> cast(attrs, [
      :name,
      :segments,
      :filled,
      :visibility,
      :background_rate,
      :paused,
      :mode,
      :influences,
      :empty_description,
      :full_description
    ])
    |> AsyncWorlds.Tensions.Tension.validate_text(:influences, 8000)
    |> AsyncWorlds.Tensions.Tension.validate_text(:empty_description, 8000)
    |> AsyncWorlds.Tensions.Tension.validate_text(:full_description, 8000)
    |> cast_embed(:triggers)
    |> validate_required([
      :name,
      :segments,
      :filled,
      :visibility,
      :background_rate,
      :paused,
      :mode
    ])
    |> validate_length(:name, max: 200)
    |> validate_change(:name, fn :name, name ->
      if String.valid?(name) and not String.contains?(name, <<0>>),
        do: [],
        else: [name: "must be valid UTF-8 without NUL characters"]
    end)
    |> validate_number(:background_rate,
      greater_than_or_equal_to: -2_147_483_648,
      less_than_or_equal_to: 2_147_483_647
    )
    |> validate_inclusion(:segments, [4, 6, 8])
    |> clamp_fill()
    |> check_constraint(:segments, name: :valid_segments)
    |> check_constraint(:filled, name: :valid_fill)
    |> check_constraint(:visibility, name: :valid_visibility)
  end

  defp clamp_fill(changeset) do
    case {get_field(changeset, :filled), get_field(changeset, :segments)} do
      {filled, segments} when is_integer(filled) and segments in [4, 6, 8] ->
        put_change(changeset, :filled, max(0, min(filled, segments)))

      _ ->
        changeset
    end
  end
end
