defmodule AsyncWorlds.Characters do
  @moduledoc "Shared, freshly authorized character operations. See docs/characters.md."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.{Character, Flags}
  alias AsyncWorlds.Discord.Snowflake

  def create_character(campaign, dm_id, attrs) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      persist(Repo.insert(Character.changeset(%Character{campaign_id: current.id}, attrs)))
    end)
  end

  def list_characters(campaign, dm_id) do
    manage(campaign, dm_id, fn current ->
      Repo.all(from c in Character, where: c.campaign_id == ^current.id, order_by: c.id)
    end)
  end

  def get_character(campaign, dm_id, character_id) do
    manage(campaign, dm_id, fn current -> fetch!(current.id, character_id) end)
  end

  def update_character(campaign, dm_id, character_id, attrs) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      character = fetch!(current.id, character_id)
      updated = character |> Character.changeset(attrs) |> Repo.update() |> persist()

      if updated.discord_user_id != character.discord_user_id,
        do: AsyncWorlds.Quests.Submissions.invalidate_open(current.id, character.id)

      updated
    end)
  end

  def set_flag(campaign, dm_id, character_id, key, flag) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      unless Flags.valid_key?(key) and Flags.valid_flag?(flag), do: Repo.rollback(:invalid_flag)
      character = fetch!(current.id, character_id)
      save_flags(character, Map.put(character.flags, key, flag))
    end)
  end

  def clear_flag(campaign, dm_id, character_id, key) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      unless Flags.valid_key?(key), do: Repo.rollback(:invalid_flag)
      character = fetch!(current.id, character_id)
      save_flags(character, Map.delete(character.flags, key))
    end)
  end

  @doc "Identity comes ONLY from a verified interaction/session, never a player-supplied character ID."
  def player_character(guild_id, verified_discord_user_id) do
    with {:ok, user_id} <- normalize(verified_discord_user_id),
         {:ok, campaign} <- Campaigns.fetch_campaign_by_guild(guild_id) do
      case Repo.get_by(Character, campaign_id: campaign.id, discord_user_id: user_id) do
        nil -> {:error, :not_found}
        character -> {:ok, player_payload(character)}
      end
    end
  end

  defp player_payload(character) do
    visible =
      character.flags
      |> Enum.filter(fn {_key, flag} ->
        Flags.valid_flag?(flag) and flag["player_visible"] == true
      end)
      |> Map.new(fn {key, flag} -> {key, Map.take(flag, ["type", "value"])} end)

    # Whitelist, not struct serialization. Hidden flags (including their keys)
    # and ownership/configuration metadata never enter player payloads.
    %{name: character.name, flags: visible}
  end

  defp manage(%Campaign{id: id} = expected, dm_id, fun) when is_integer(id) and id > 0 do
    with {:ok, user_id} <- normalize(dm_id) do
      Repo.transaction(fn ->
        current = Repo.one(from c in Campaign, where: c.id == ^expected.id, lock: "FOR UPDATE")
        unless current, do: Repo.rollback(:not_found)
        unless Campaigns.dm?(current, user_id), do: Repo.rollback(:unauthorized)

        if Map.take(current, [:discord_guild_id, :dm_user_id, :public_channel_id]) !=
             Map.take(expected, [:discord_guild_id, :dm_user_id, :public_channel_id]),
           do: Repo.rollback(:stale_campaign)

        fun.(current)
      end)
    end
  end

  defp manage(_, _, _), do: {:error, :invalid_campaign}

  defp fetch!(campaign_id, character_id) do
    with {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:id, character_id),
         %Character{} = character <- Repo.get_by(Character, campaign_id: campaign_id, id: id) do
      character
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp mutable!(campaign) do
    if campaign.clock_mutations_locked, do: Repo.rollback(:tick_locked)
  end

  defp save_flags(character, flags),
    do: persist(Repo.update(Character.changeset(character, %{flags: flags})))

  defp persist({:ok, value}), do: value
  defp persist({:error, changeset}), do: Repo.rollback(changeset)

  defp normalize(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end
end
