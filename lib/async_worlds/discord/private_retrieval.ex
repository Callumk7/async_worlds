defmodule AsyncWorlds.Discord.PrivateRetrieval do
  @moduledoc "Fresh subject-authorized history independent of outbound delivery state."
  import Ecto.Query
  alias AsyncWorlds.{PlayerAccess, Repo}
  alias AsyncWorlds.Ticks.{Publication, Snapshot, Tick}
  alias AsyncWorlds.Quests.Rules

  def result(guild, access) do
    PlayerAccess.run(guild, access, fn campaign, character ->
      owner = historical_owner(character, access)
      personal = [%{character_id: character.id}]
      id = %{id: character.id}

      publication =
        Repo.one(
          from p in Publication,
            join: t in Tick,
            on: t.id == p.tick_id,
            where:
              t.campaign_id == ^campaign.id and t.status == :published and
                fragment("?->'characters' @> ?::jsonb", p.payload, ^owner) and
                fragment("?->'private_results' @> ?::jsonb", p.payload, ^personal) and
                (fragment("?->'players' @> ?::jsonb", p.outputs, ^personal) or
                   fragment(
                     "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'characters', '[]'::jsonb)) c JOIN jsonb_array_elements(COALESCE(?->'players', '[]'::jsonb)) m ON m->>'recipient_id' = c->>'discord_user_id' WHERE c @> ?::jsonb)",
                     p.payload,
                     p.outputs,
                     ^id
                   )),
            order_by: [desc: t.number],
            limit: 1
        )

      messages =
        if publication do
          frozen = Enum.find(publication.payload["characters"], &(&1["id"] == character.id))

          Enum.filter(publication.outputs["players"] || [], fn message ->
            if publication.payload["schema_version"] == 3 do
              message["character_id"] == character.id and
                message["delivery_audience"] in ["owner", "dm_controlled"]
            else
              message["recipient_id"] == frozen["discord_user_id"]
            end
          end)
        else
          []
        end

      if messages == [],
        do: "No published personal result yet.",
        else: Enum.map_join(messages, "", & &1["content"])
    end)
  end

  def submission(guild, access) do
    PlayerAccess.run(guild, access, fn campaign, character ->
      owner = historical_owner(character, access)
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
        revision = Enum.find(inputs["revisions"], &(&1["id"] == input["revision_id"]))
        node = Rules.node(revision["definition"], input["node_id"])
        label = Enum.find(node["choices"], &(&1["id"] == input["choice_id"]))["label"]

        "Tick #{snapshot.data["tick_number"]} — Latest choice: #{label} (closed). Use /quest for your current quest and /result for your approved result."
      else
        :no_submission
      end
    end)
  end

  # Normal members may not inherit previous owners' history. The actual DM,
  # through a freshly checked persona, can inspect the selected character's history.
  defp historical_owner(character, %{debug: true}), do: [%{id: character.id}]

  defp historical_owner(character, _),
    do: [%{id: character.id, discord_user_id: character.discord_user_id}]
end
