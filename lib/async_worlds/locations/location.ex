defmodule AsyncWorlds.Locations.Location do
  @moduledoc "A campaign-owned location with optional descriptive kind and parent."
  use Ecto.Schema
  import Ecto.Changeset

  schema "locations" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    field :name, :string
    field :description, :string
    field :kind, :string
    belongs_to :parent, __MODULE__

    timestamps(type: :utc_datetime)
  end

  @doc "Validates editable fields; campaign ownership is assigned by the context."
  def changeset(location, attrs) do
    location
    |> cast(attrs, [:name, :description, :kind])
    |> validate_required([:name])
    |> validate_length(:name, max: 200, count: :codepoints)
    |> validate_change(:name, &validate_text/2)
    |> validate_change(:description, &validate_text/2)
    |> validate_change(:kind, &validate_text/2)
    |> foreign_key_constraint(:campaign_id)
  end

  @doc false
  def parent_changeset(location, parent_id) do
    location
    |> change(parent_id: parent_id)
    |> foreign_key_constraint(:parent_id)
    |> check_constraint(:parent_id, name: :locations_not_self_parent)
  end

  defp validate_text(field, value) do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: [],
      else: [{field, "must be valid UTF-8 without NUL characters"}]
  end
end
