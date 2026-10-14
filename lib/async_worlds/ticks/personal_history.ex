defmodule AsyncWorlds.Ticks.PersonalHistory do
  @moduledoc """
  Structured, subject-authorized personal history, independent of delivery status.

  Player calls resolve a verified identity/persona through PlayerAccess. Previous
  owners' history is not inherited. DM calls select a campaign-owned character
  explicitly under DMAccess, without manufacturing a player identity/persona.
  Empty history returns {:ok, nil}. Only whitelisted personal fields are returned,
  never raw publications, snapshots, delivery routes or Discord command guidance.
  """
  import Ecto.Query
  alias AsyncWorlds.{DMAccess, PlayerAccess, Repo}
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Ticks.{Publication, Snapshot, Tick}
  alias AsyncWorlds.Quests.Rules

  def result(guild, access) do
    PlayerAccess.run(guild, access, fn campaign, character ->
      result_for(campaign, character, historical_owner(character, access))
    end)
  end

  def submission(guild, access) do
    PlayerAccess.run(guild, access, fn campaign, character ->
      submission_for(campaign, character, historical_owner(character, access))
    end)
  end

  def dm_result(scope, character_id),
    do: dm(scope, character_id, &result_for/3)

  def dm_submission(scope, character_id),
    do: dm(scope, character_id, &submission_for/3)

  defp dm(scope, character_id, fun) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, id} when id > 0 and id <= 9_223_372_036_854_775_807 <-
             Ecto.Type.cast(:id, character_id),
           %Character{} = character <- Repo.get_by(Character, campaign_id: campaign.id, id: id) do
        {:ok, fun.(campaign, character, [%{id: character.id}])}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  defp result_for(campaign, character, owner) do
    personal = [%{character_id: character.id}]
    id = %{id: character.id}

    saved =
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
          limit: 1,
          select: %{publication: p, tick_number: t.number, published_at: t.published_at}
      )

    if saved do
      publication = saved.publication
      frozen = Enum.find(publication.payload["characters"], &(&1["id"] == character.id))

      chunks =
        (publication.outputs["players"] || [])
        |> Enum.filter(fn message ->
          if publication.payload["schema_version"] == 3 do
            message["character_id"] == character.id and
              message["delivery_audience"] in ["owner", "dm_controlled"]
          else
            message["recipient_id"] == frozen["discord_user_id"]
          end
        end)
        |> Enum.map(& &1["content"])

      if chunks != [] do
        %{
          tick_id: publication.tick_id,
          tick_number: saved.tick_number,
          published_at: saved.published_at,
          character_id: character.id,
          content_chunks: chunks
        }
      end
    end
  end

  defp submission_for(campaign, character, owner) do
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
      choice = Enum.find(node["choices"], &(&1["id"] == input["choice_id"]))

      %{
        tick_id: snapshot.tick_id,
        tick_number: snapshot.data["tick_number"],
        character_id: character.id,
        choice_id: input["choice_id"],
        choice_label: choice["label"]
      }
    end
  end

  # PlayerAccess freshly validates debug persona permissions before reaching here.
  defp historical_owner(character, %{debug: true}), do: [%{id: character.id}]

  defp historical_owner(character, _),
    do: [%{id: character.id, discord_user_id: character.discord_user_id}]
end
