defmodule AsyncWorlds.Quests.FrozenInputs do
  @moduledoc "Pure validation of the v2 quest input contract. Never consults live state."
  alias AsyncWorlds.Characters.Flags
  alias AsyncWorlds.Quests.{Definition, Rules}

  def valid?(inputs, clocks) when is_map(inputs) do
    with true <-
           Enum.sort(Map.keys(inputs)) ==
             Enum.sort(~w(characters progressions quests revisions submissions invalidations)),
         true <- Enum.all?(Map.values(inputs), &is_list/1),
         true <- ordered?(inputs["characters"], "id"),
         true <- ordered?(inputs["progressions"], "id"),
         true <- ordered?(inputs["quests"], "id"),
         true <- ordered?(inputs["revisions"], "id"),
         true <- ordered?(inputs["submissions"], "character_id"),
         true <- ordered?(inputs["invalidations"], "character_id") do
      clock_map =
        Map.new(
          clocks,
          &{&1["id"],
           %{filled: &1["filled"], segments: &1["segments"], completed: &1["completed"]}}
        )

      characters = Map.new(inputs["characters"], &{&1["id"], &1})
      quests = Map.new(inputs["quests"], &{&1["id"], &1})
      revisions = Map.new(inputs["revisions"], &{&1["id"], &1})
      progressions = Map.new(inputs["progressions"], &{&1["id"], &1})

      valid_targets?(clocks, characters, quests) and
        unique?(inputs["characters"], "discord_user_id") and
        unique?(inputs["quests"], "content_id") and
        Enum.all?(inputs["characters"], fn c ->
          exact?(c, ~w(id name discord_user_id flags)) and Definition.text?(c["name"]) and
            is_binary(c["discord_user_id"]) and Flags.valid?(c["flags"])
        end) and
        Enum.all?(inputs["quests"], fn q ->
          exact?(q, ~w(id content_id name)) and Definition.id?(q["content_id"]) and
            Definition.text?(q["name"])
        end) and
        Enum.all?(inputs["revisions"], fn r ->
          exact?(r, ~w(id quest_id number definition)) and Map.has_key?(quests, r["quest_id"]) and
            positive?(r["number"]) and Definition.valid?(r["definition"], clock_map, :frozen)
        end) and
        unique?(inputs["progressions"], "character_id") and
        Enum.all?(inputs["progressions"], fn p ->
          r = revisions[p["revision_id"]]
          node = r && Rules.node(r["definition"], p["node_id"])

          exact?(p, ~w(id character_id revision_id node_id position_version status)) and
            Map.has_key?(characters, p["character_id"]) and positive?(p["position_version"]) and
            p["status"] == "active" and not is_nil(node) and not node["ending"]
        end) and
        Enum.all?(inputs["submissions"], fn s ->
          p = progressions[s["progression_id"]]
          c = characters[s["character_id"]]
          r = p && revisions[p["revision_id"]]
          node = r && Rules.node(r["definition"], p["node_id"])
          choice = node && Enum.find(node["choices"], &(&1["id"] == s["choice_id"]))

          exact?(
            s,
            ~w(character_id progression_id revision_id node_id position_version choice_id)
          ) and
            not is_nil(p) and not is_nil(c) and not is_nil(choice) and
            Enum.all?(~w(character_id revision_id node_id position_version), &(s[&1] == p[&1])) and
            Rules.eligible?(choice, c["flags"], clock_map)
        end) and
        Enum.all?(inputs["invalidations"], fn i ->
          exact?(i, ~w(character_id reason)) and Map.has_key?(characters, i["character_id"]) and
            i["reason"] == "stale_or_ineligible" and
            not Enum.any?(inputs["submissions"], &(&1["character_id"] == i["character_id"]))
        end)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid?(_, _), do: false

  defp valid_targets?(clocks, characters, quests) do
    Enum.all?(clocks, fn clock ->
      Enum.all?(clock["triggers"], fn trigger ->
        changeset = AsyncWorlds.Clocks.Trigger.changeset(%AsyncWorlds.Clocks.Trigger{}, trigger)

        changeset.valid? and
          case trigger["type"] do
            "set_flag" ->
              Map.has_key?(characters, trigger["character_id"])

            "unlock_quest" ->
              Map.has_key?(characters, trigger["character_id"]) and
                Map.has_key?(quests, trigger["quest_id"])

            _ ->
              true
          end
      end)
    end)
  end

  defp exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp positive?(id), do: is_integer(id) and id > 0
  defp unique?(items, key), do: length(Enum.uniq_by(items, & &1[key])) == length(items)

  defp ordered?(items, key) do
    ids = Enum.map(items, & &1[key])
    Enum.all?(ids, &positive?/1) and ids == Enum.sort(Enum.uniq(ids))
  end
end
