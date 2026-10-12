defmodule AsyncWorlds.PlayerAccess do
  @moduledoc "Gameplay subject resolution. Verified actors never become impersonated Discord identities."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Discord.{DebugSessions, Snowflake}
  require Logger

  def context(campaign, verified_actor) do
    with {:ok, actor} <- normalize(verified_actor) do
      Repo.transaction(fn ->
        current = lock!(campaign.id)

        unless current.discord_guild_id == campaign.discord_guild_id,
          do: Repo.rollback(:unauthorized)

        session = if Campaigns.dm?(current, actor), do: DebugSessions.current(current)

        if session && session.enabled && session.role == :player do
          unless is_integer(session.character_id), do: Repo.rollback(:not_found)

          character =
            Repo.get_by(Character, campaign_id: current.id, id: session.character_id) ||
              Repo.rollback(:not_found)

          access = %{
            actor_id: actor,
            character_id: character.id,
            generation: session.generation,
            debug: true,
            guild_id: current.discord_guild_id,
            public_channel_id: current.public_channel_id
          }

          %{
            campaign: current,
            user_id: actor,
            access: access,
            role: :player,
            debug_character: character.name,
            generation: session.generation
          }
        else
          %{
            campaign: current,
            user_id: actor,
            access: actor,
            role: if(Campaigns.dm?(current, actor), do: :dm, else: :player)
          }
        end
      end)
    end
  end

  def run(guild, access, fun) do
    with {:ok, expected} <- Campaigns.fetch_campaign_by_guild(guild),
         {:ok, actor} <- actor(access) do
      Repo.transaction(fn ->
        campaign = lock!(expected.id)

        unless campaign.discord_guild_id == expected.discord_guild_id,
          do: Repo.rollback(:not_found)

        character = subject!(campaign, actor, access)
        fun.(campaign, character)
      end)
    end
  end

  def audit(%{debug: true, actor_id: actor, character_id: character}, campaign_id, operation) do
    Logger.info("Discord debug gameplay mutation",
      actor_id: actor,
      character_id: character,
      campaign_id: campaign_id,
      operation: operation
    )
  end

  def audit(_, _, _), do: :ok

  defp subject!(
         campaign,
         actor,
         %{debug: true, character_id: id, generation: generation} = access
       ) do
    session = DebugSessions.current(campaign)

    unless Campaigns.dm?(campaign, actor) && session && session.enabled && session.role == :player &&
             session.character_id == id && session.generation == generation &&
             access.guild_id == campaign.discord_guild_id &&
             access.public_channel_id == campaign.public_channel_id,
           do: Repo.rollback(:stale_component)

    Repo.get_by(Character, campaign_id: campaign.id, id: id) || Repo.rollback(:not_found)
  end

  defp subject!(campaign, actor, access) when is_binary(access) or is_integer(access) do
    Repo.get_by(Character, campaign_id: campaign.id, discord_user_id: actor) ||
      Repo.rollback(:not_found)
  end

  defp subject!(_, _, _), do: Repo.rollback(:unauthorized)

  defp actor(%{debug: true, actor_id: actor}), do: normalize(actor)
  defp actor(actor), do: normalize(actor)

  defp normalize(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp lock!(id),
    do:
      Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:not_found)
end
