defmodule AsyncWorlds.Factions.Membership do
  @moduledoc "A current, DM-only character–faction membership with an optional descriptive role."
  use Ecto.Schema
  import Ecto.Changeset

  schema "faction_memberships" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    belongs_to :character, AsyncWorlds.Characters.Character
    belongs_to :faction, AsyncWorlds.Factions.Faction
    field :role, :string
    timestamps(type: :utc_datetime)
  end

  @doc "Only role is editable; the context assigns immutable endpoints and campaign."
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_length(:role, max: 200, count: :codepoints)
    |> validate_change(:role, fn :role, role ->
      if String.valid?(role) and not String.contains?(role, <<0>>),
        do: [],
        else: [role: "must be valid UTF-8 without NUL characters"]
    end)
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:character_id)
    |> foreign_key_constraint(:faction_id)
    |> unique_constraint([:character_id, :faction_id])
  end
end
