defmodule AsyncWorlds.Ticks.EventReferences do
  @moduledoc "Minimal typed Event context, captured from campaign-owned frozen inputs, never live names."
  import Ecto.Query
  alias AsyncWorlds.Repo

  def freeze(campaign_id) do
    for {type, module} <- [
          {"location", AsyncWorlds.Locations.Location},
          {"character", AsyncWorlds.Characters.Character},
          {"faction", AsyncWorlds.Factions.Faction}
        ],
        record <-
          Repo.all(from r in module, where: r.campaign_id == ^campaign_id, order_by: r.id),
        do: %{"entity" => type, "id" => record.id, "name" => record.name}
  end

  def attach(event, state, originals, changes) do
    # Absence preserves the exact replay shape of already saved reviews.
    if Map.has_key?(event, "references") or Map.has_key?(event, "follow_on") do
      refs = Map.get(event, "references", [])
      follow = Map.get(event, "follow_on", [])
      true = is_list(refs) and length(refs) <= 100
      true = is_list(follow) and length(follow) <= 100
      context = state.context ++ Enum.map(state.tensions, &tension_ref/1)

      refs =
        Enum.map(refs, fn ref ->
          true = is_map(ref) and Enum.sort(Map.keys(ref)) == ["entity", "id"]
          find!(context, ref["entity"], ref["id"])
        end)

      follow =
        Enum.map(follow, fn id ->
          true =
            Enum.any?(
              changes,
              &(&1["entity"] == "tension" and &1["id"] == id and is_nil(&1["before"]))
            )

          find!(context, "tension", id)
        end)

      inferred =
        for c <- changes,
            id <- tension_ids(c),
            do: find!(context, "tension", id)

      refs = Enum.uniq_by(refs ++ inferred ++ follow, &{&1["entity"], &1["id"]})

      if event["audience"] == "public" do
        true =
          Enum.all?(refs, fn r ->
            r["entity"] != "tension" or
              Enum.all?(
                Enum.filter(originals ++ state.tensions, &(&1["id"] == r["id"])),
                &(&1["audience"] == "public")
              )
          end)
      end

      event
      |> Map.put("references", Enum.map(refs, &Map.take(&1, ~w(entity id name))))
      |> Map.put("follow_on", Enum.map(follow, &Map.take(&1, ~w(entity id name))))
    else
      event
    end
  end

  defp tension_ids(%{"entity" => "tension", "id" => id}), do: [id]

  defp tension_ids(c),
    do:
      [get_in(c, ["before", "tension_id"]), get_in(c, ["after", "tension_id"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

  defp tension_ref(t), do: %{"entity" => "tension", "id" => t["id"], "name" => t["name"]}

  defp find!(context, type, id) do
    true = type in ~w(location character faction tension) and (is_integer(id) or is_binary(id))

    Enum.find(context, &(&1["entity"] == type and &1["id"] == id)) ||
      raise ArgumentError, "invalid reference"
  end

  def published(event, payload) do
    ids = payload["published_entity_ids"] || %{}
    resolve = fn id -> Map.get(ids, id, id) end

    inferred =
      for c <- event["changes"] || [],
          id <- tension_ids(c) do
        t =
          if(c["entity"] == "tension",
            do: c["after"],
            else:
              Enum.find(
                payload["tensions"] || [],
                &(resolve.(&1["id"]) == resolve.(id) and
                    (event["audience"] != "public" or &1["audience"] == "public"))
              )
          )

        %{
          "entity" => "tension",
          "id" => id,
          "name" =>
            if(t, do: t["name"], else: "Tension ##{resolve.(id)} (historical name not recorded)")
        }
      end

    refs = Enum.uniq_by((event["references"] || []) ++ inferred, &{&1["entity"], &1["id"]})

    map = fn refs ->
      refs |> Enum.map(&Map.update!(&1, "id", resolve)) |> Enum.uniq_by(&{&1["entity"], &1["id"]})
    end

    event
    |> Map.put("references", map.(refs))
    |> Map.put("follow_on", map.(event["follow_on"] || []))
  end
end
