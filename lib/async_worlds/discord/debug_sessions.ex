defmodule AsyncWorlds.Discord.DebugSessions do
  @moduledoc "Freshly authorized persona transitions serialized on the gameplay campaign lock."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Discord.{DebugSession, Snowflake}
  require Logger

  def current(campaign) do
    case Repo.get_by(DebugSession, campaign_id: campaign.id) do
      %DebugSession{} = session -> if matches?(session, campaign), do: session
      nil -> nil
    end
  end

  def matches?(session, campaign) do
    session.dm_user_id == campaign.dm_user_id and
      session.guild_id == campaign.discord_guild_id and
      session.public_channel_id == campaign.public_channel_id
  end

  def transition(guild, actor, operation) do
    with {:ok, actor} <- cast(actor),
         {:ok, expected} <- Campaigns.fetch_campaign_by_guild(guild) do
      result =
        Repo.transaction(fn ->
          campaign =
            Repo.one!(from c in Campaign, where: c.id == ^expected.id, lock: "FOR UPDATE")

          unless campaign.discord_guild_id == expected.discord_guild_id and
                   Campaigns.dm?(campaign, actor),
                 do: Repo.rollback(:unauthorized)

          old = Repo.get_by(DebugSession, campaign_id: campaign.id)

          session =
            current(campaign) ||
              %DebugSession{
                id: old && old.id,
                campaign_id: campaign.id,
                dm_user_id: campaign.dm_user_id,
                guild_id: campaign.discord_guild_id,
                public_channel_id: campaign.public_channel_id,
                generation: if(old, do: old.generation, else: 0)
              }

          attrs =
            case operation do
              {:player, id} ->
                with {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
                       Ecto.Type.cast(:id, id),
                     %Character{} <- Repo.get_by(Character, campaign_id: campaign.id, id: id) do
                  %{enabled: true, role: :player, character_id: id}
                else
                  _ -> Repo.rollback(:not_found)
                end

              :dm ->
                %{enabled: true, role: :dm, character_id: nil}

              :off ->
                %{enabled: false, role: :dm, character_id: nil, copy_messages: false}

              {:messages, enabled} when is_boolean(enabled) ->
                %{copy_messages: enabled}

              _ ->
                Repo.rollback(:unknown_command)
            end

          attrs = Map.put(attrs, :generation, session.generation + 1)
          # A changed campaign invalidates all settings, including a previous DM's copies.
          record = old || %DebugSession{}

          base =
            Map.take(session, [
              :campaign_id,
              :dm_user_id,
              :guild_id,
              :public_channel_id,
              :enabled,
              :role,
              :character_id,
              :copy_messages
            ])

          record |> Ecto.Changeset.change(Map.merge(base, attrs)) |> Repo.insert_or_update!()
        end)

      case result do
        {:ok, session} ->
          Logger.info("Discord debug transition",
            campaign_id: expected.id,
            actor_id: actor,
            character_id: session.character_id,
            operation: operation_name(operation)
          )

        _ ->
          :ok
      end

      result
    end
  end

  defp operation_name({name, _}), do: name
  defp operation_name(name), do: name

  defp cast(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end
end
