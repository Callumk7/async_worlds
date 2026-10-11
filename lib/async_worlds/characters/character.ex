defmodule AsyncWorlds.Characters.Character do
  @moduledoc "A campaign-owned character linked to one Discord identity."
  use Ecto.Schema
  import Ecto.Changeset
  alias AsyncWorlds.Characters.Flags
  alias AsyncWorlds.Discord.Snowflake

  schema "characters" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    field :discord_user_id, Snowflake
    field :name, :string
    field :flags, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def changeset(character, attrs) do
    character
    |> cast(attrs, [:name, :discord_user_id, :flags])
    |> validate_required([:name, :discord_user_id])
    |> validate_length(:name, max: 200, count: :codepoints)
    |> validate_change(:name, fn :name, name ->
      if String.valid?(name) and not String.contains?(name, <<0>>),
        do: [],
        else: [name: "must be valid UTF-8 without NUL characters"]
    end)
    |> validate_change(:flags, fn :flags, flags ->
      if Flags.valid?(flags),
        do: [],
        else: [flags: "must contain typed facts with explicit visibility"]
    end)
    |> validate_flags_present()
    |> unique_constraint(:discord_user_id, name: :characters_campaign_id_discord_user_id_index)
    |> foreign_key_constraint(:campaign_id)
    |> check_constraint(:discord_user_id, name: :characters_discord_user_id_valid)
  end

  defp validate_flags_present(changeset) do
    if is_nil(get_field(changeset, :flags)),
      do: add_error(changeset, :flags, "must be an object"),
      else: changeset
  end
end
