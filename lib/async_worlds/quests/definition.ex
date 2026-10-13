defmodule AsyncWorlds.Quests.Definition do
  @moduledoc "Strict typed quest content validation. Clock references are supplied by the owning campaign."
  alias AsyncWorlds.Characters.Flags

  def valid?(definition, clocks, mode \\ :authoring) do
    with true <- valid_clocks?(clocks),
         true <- keys?(definition, ~w(start_node nodes)),
         nodes when is_list(nodes) and nodes != [] <- definition["nodes"],
         true <- Enum.all?(nodes, &node_shape?/1),
         ids = Enum.map(nodes, & &1["id"]),
         true <- unique?(ids),
         true <- definition["start_node"] in ids,
         choices = Enum.flat_map(nodes, & &1["choices"]),
         true <- unique?(Enum.map(choices, & &1["id"])) do
      Enum.all?(choices, &choice?(&1, ids, clocks, mode))
    else
      _ -> false
    end
  end

  @doc "Field-path diagnostics shared by imports and form releases; strict typed validation remains authoritative."
  def errors(definition, clocks) do
    if valid?(definition, clocks) do
      []
    else
      diagnose(definition, clocks)
    end
  end

  defp diagnose(%{"nodes" => nodes} = definition, clocks) when is_list(nodes) do
    ids = Enum.map(nodes, &field(&1, "id"))

    choices =
      Enum.flat_map(nodes, fn n ->
        case field(n, "choices") do
          list when is_list(list) -> list
          _ -> []
        end
      end)

    choice_ids = Enum.map(choices, &field(&1, "id"))

    errors =
      issue([], "start_node", definition["start_node"] in ids, "Choose an existing start node")

    errors = issue(errors, "nodes", nodes != [], "Add at least one node")

    errors =
      Enum.with_index(nodes)
      |> Enum.reduce(errors, fn {node, i}, acc ->
        path = "nodes[#{i}]"
        id = field(node, "id")
        cs = field(node, "choices")

        acc =
          acc
          |> issue(
            path <> ".id",
            id?(id) and Enum.count(ids, &(&1 == id)) == 1,
            "Node ID must be valid and unique"
          )
          |> issue(
            path <> ".text",
            text?(field(node, "text")),
            "Narrative text is required (maximum 8000 bytes)"
          )
          |> issue(
            path <> ".choices",
            is_list(cs) and if(field(node, "ending") == true, do: cs == [], else: cs != []),
            "Endings have no choices; other nodes need choices"
          )

        if is_list(cs) do
          Enum.with_index(cs)
          |> Enum.reduce(acc, fn {choice, j}, acc ->
            cp = path <> ".choices[#{j}]"
            cid = field(choice, "id")

            acc =
              acc
              |> issue(
                cp <> ".id",
                id?(cid) and Enum.count(choice_ids, &(&1 == cid)) == 1,
                "Choice ID must be valid and unique"
              )
              |> issue(cp <> ".label", text?(field(choice, "label")), "Choice label is required")

            outcomes = field(choice, "outcomes")

            acc =
              if is_map(outcomes) do
                Enum.reduce(outcomes, acc, fn {key, outcome}, acc ->
                  op = cp <> ".outcomes." <> key

                  acc
                  |> issue(
                    op <> ".text",
                    text?(field(outcome, "text")),
                    "Outcome text is required"
                  )
                  |> issue(
                    op <> ".next_node",
                    field(outcome, "next_node") in ids,
                    "Choose an existing destination"
                  )
                end)
              else
                issue(acc, cp <> ".outcomes", false, "Outcomes are required")
              end

            issue(
              acc,
              cp,
              is_map(choice) and choice?(choice, ids, clocks, :authoring),
              "Invalid choice, condition, effect or outcome configuration"
            )
          end)
        else
          acc
        end
      end)

    issue(
      errors,
      "definition",
      keys?(definition, ~w(start_node nodes)) and Enum.all?(nodes, &node_shape?/1),
      "Invalid node shape or ending configuration"
    )
    |> case do
      [] -> [{"definition", "Invalid definition or campaign clock references"}]
      errors -> Enum.reverse(errors)
    end
  end

  defp diagnose(_, _), do: [{"definition", "A definition with nodes is required"}]
  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_, _), do: nil
  defp issue(errors, _, true, _), do: errors
  defp issue(errors, path, _, message), do: [{path, message} | errors]

  defp valid_clocks?(clocks) when is_map(clocks) do
    Enum.all?(clocks, fn
      {id, %{segments: segments, filled: filled, completed: completed}}
      when is_integer(id) and id > 0 and segments in [4, 6, 8] and
             is_integer(filled) and filled >= 0 and filled <= segments and is_boolean(completed) ->
        true

      _ ->
        false
    end)
  end

  defp valid_clocks?(_), do: false

  def id?(id),
    do: is_binary(id) and byte_size(id) in 1..100 and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id)

  def text?(text),
    do:
      is_binary(text) and String.valid?(text) and String.trim(text) != "" and
        byte_size(text) in 1..8000 and
        not String.contains?(text, <<0>>)

  def keys?(map, keys),
    do: is_map(map) and not is_struct(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp unique?(ids), do: length(ids) == length(Enum.uniq(ids))

  defp node_shape?(node) do
    keys?(node, ~w(id text ending choices)) and id?(node["id"]) and text?(node["text"]) and
      is_boolean(node["ending"]) and is_list(node["choices"]) and
      if(node["ending"], do: node["choices"] == [], else: node["choices"] != []) and
      Enum.all?(node["choices"], &(is_map(&1) and not is_struct(&1)))
  end

  defp choice?(choice, nodes, clocks, mode) do
    fields = ~w(id label eligibility conditions mode outcomes)
    fields = if choice["mode"] == "rolled", do: fields ++ ~w(dice critical_effects), else: fields

    keys?(choice, fields) and id?(choice["id"]) and text?(choice["label"]) and
      choice["eligibility"] in ~w(hidden disabled) and is_list(choice["conditions"]) and
      Enum.all?(choice["conditions"], &condition?(&1, clocks, mode)) and
      config?(choice, nodes, clocks)
  end

  defp config?(%{"mode" => "fixed", "outcomes" => outcomes}, nodes, clocks),
    do: keys?(outcomes, ["fixed"]) and outcome?(outcomes["fixed"], nodes, clocks)

  defp config?(
         %{
           "mode" => "rolled",
           "dice" => dice,
           "outcomes" => outcomes,
           "critical_effects" => bonus
         },
         nodes,
         clocks
       ),
       do:
         dice in [1, 2, 3] and keys?(outcomes, ~w(success partial failure)) and
           Enum.all?(Map.values(outcomes), &outcome?(&1, nodes, clocks)) and
           effects?(bonus, clocks)

  defp config?(_, _, _), do: false

  defp outcome?(outcome, nodes, clocks),
    do:
      keys?(outcome, ~w(text next_node effects)) and text?(outcome["text"]) and
        outcome["next_node"] in nodes and effects?(outcome["effects"], clocks)

  defp condition?(
         %{"type" => "clock_threshold", "clock_id" => id, "operator" => op, "value" => value} = c,
         clocks,
         mode
       ) do
    keys?(c, ~w(type clock_id operator value)) and is_integer(id) and Map.has_key?(clocks, id) and
      op in ~w(gte lte) and is_integer(value) and value >= 0 and
      (mode == :frozen or value <= Map.fetch!(clocks, id).segments)
  end

  defp condition?(
         %{"type" => "character_flag", "key" => key, "value" => value, "flag_type" => type} = c,
         _,
         _mode
       ),
       do:
         keys?(c, ~w(type key value flag_type)) and Flags.valid_key?(key) and
           Flags.valid_flag?(%{"type" => type, "value" => value, "player_visible" => false})

  defp condition?(_, _, _), do: false

  def condition?(condition, clocks), do: condition?(condition, clocks, :authoring)

  def effects?(effects, clocks), do: is_list(effects) and Enum.all?(effects, &effect?(&1, clocks))

  def effect?(%{"type" => "clock_delta", "clock_id" => id, "delta" => delta} = e, clocks),
    do:
      keys?(e, ~w(type clock_id delta)) and is_integer(id) and Map.has_key?(clocks, id) and
        is_integer(delta) and delta in -1_000_000..1_000_000

  def effect?(%{"type" => "set_flag", "key" => key, "flag" => flag} = e, _),
    do: keys?(e, ~w(type key flag)) and Flags.valid_key?(key) and Flags.valid_flag?(flag)

  def effect?(%{"type" => "clear_flag", "key" => key} = e, _),
    do: keys?(e, ~w(type key)) and Flags.valid_key?(key)

  def effect?(_, _), do: false
end
