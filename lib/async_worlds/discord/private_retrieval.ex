defmodule AsyncWorlds.Discord.PrivateRetrieval do
  @moduledoc "Fresh owner-authorized command fallback independent of outbound delivery state."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Ticks.{Publication, Snapshot, Tick}
  alias AsyncWorlds.Quests.Rules
  alias AsyncWorlds.Discord.Snowflake

  def result(guild, user) do
    player(guild, user, fn campaign, character ->
      owner = [%{id: character.id, discord_user_id: character.discord_user_id}]
      recipient = [%{recipient_id: character.discord_user_id}]
      personal = [%{character_id: character.id}]

      publication =
        Repo.one(
          from p in Publication,
            join: t in Tick,
            on: t.id == p.tick_id,
            where:
              t.campaign_id == ^campaign.id and t.status == :published and
                fragment("?->'characters' @> ?::jsonb", p.payload, ^owner) and
                fragment("?->'private_results' @> ?::jsonb", p.payload, ^personal) and
                fragment("?->'players' @> ?::jsonb", p.outputs, ^recipient),
            order_by: [desc: t.number],
            limit: 1
        )

      messages =
        if publication,
          do:
            Enum.filter(
              publication.outputs["players"] || [],
              &(&1["recipient_id"] == character.discord_user_id)
            ),
          else: []

      if messages == [],
        do: "No published personal result yet.",
        else: Enum.map_join(messages, "", & &1["content"])
    end)
  end

  def submission(guild, user) do
    player(guild, user, fn campaign, character ->
      owner = [%{id: character.id, discord_user_id: character.discord_user_id}]
      participant = [%{character_id: character.id}]

      snapshot =
        Repo.one(
          from s in Snapshot,
            join: t in Tick,
            on: t.id == s.tick_id,
            where:
              t.campaign_id == ^campaign.id and
                fragment("?->'quest_inputs'->'characters' @> ?::jsonb", s.data, ^owner) and
                fragment("?->'quest_inputs'->'submissions' @> ?::jsonb", s.data, ^participant),
            order_by: [desc: t.number],
            limit: 1
        )

      if snapshot do
        inputs = snapshot.data["quest_inputs"]
        input = Enum.find(inputs["submissions"], &(&1["character_id"] == character.id))

        label =
          if input do
            revision = Enum.find(inputs["revisions"], &(&1["id"] == input["revision_id"]))
            node = Rules.node(revision["definition"], input["node_id"])
            Enum.find(node["choices"], &(&1["id"] == input["choice_id"]))["label"]
          else
            "None"
          end

        "Tick #{snapshot.data["tick_number"]} — Latest choice: #{label} (closed). Use /quest for your current quest and /result for your approved result."
      else
        :no_submission
      end
    end)
  end

  defp player(guild, verified_user, fun) do
    with {:ok, user} <- Snowflake.cast(verified_user),
         {:ok, expected} <- Campaigns.fetch_campaign_by_guild(guild) do
      Repo.transaction(fn ->
        campaign = Repo.one!(from c in Campaign, where: c.id == ^expected.id, lock: "FOR UPDATE")
        if campaign.discord_guild_id != expected.discord_guild_id, do: Repo.rollback(:not_found)

        character =
          Repo.get_by(Character, campaign_id: campaign.id, discord_user_id: user) ||
            Repo.rollback(:not_found)

        fun.(campaign, character)
      end)
    else
      :error -> {:error, :invalid_id}
      error -> error
    end
  end
end
