defmodule AsyncWorlds.Quests.Definition do
  @moduledoc "Strict typed quest content validation. Clock references are supplied by the owning campaign."
  alias AsyncWorlds.Characters.Flags

  def valid?(definition, clocks) do
    with true <- valid_clocks?(clocks),
         true <- keys?(definition, ~w(start_node nodes)),
         nodes when is_list(nodes) and nodes != [] <- definition["nodes"],
         true <- Enum.all?(nodes, &node_shape?/1),
         ids = Enum.map(nodes, & &1["id"]),
         true <- unique?(ids),
         true <- definition["start_node"] in ids,
         choices = Enum.flat_map(nodes, & &1["choices"]),
         true <- unique?(Enum.map(choices, & &1["id"])) do
      Enum.all?(choices, &choice?(&1, ids, clocks))
    else
      _ -> false
    end
  end

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
      is_binary(text) and String.valid?(text) and byte_size(text) in 1..8000 and
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

  defp choice?(choice, nodes, clocks) do
    fields = ~w(id label eligibility conditions mode outcomes)
    fields = if choice["mode"] == "rolled", do: fields ++ ~w(dice critical_effects), else: fields

    keys?(choice, fields) and id?(choice["id"]) and text?(choice["label"]) and
      choice["eligibility"] in ~w(hidden disabled) and is_list(choice["conditions"]) and
      Enum.all?(choice["conditions"], &condition?(&1, clocks)) and
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

  def condition?(
        %{"type" => "clock_threshold", "clock_id" => id, "operator" => op, "value" => value} = c,
        clocks
      ) do
    keys?(c, ~w(type clock_id operator value)) and is_integer(id) and Map.has_key?(clocks, id) and
      op in ~w(gte lte) and is_integer(value) and value >= 0 and
      value <= Map.fetch!(clocks, id).segments
  end

  def condition?(
        %{"type" => "character_flag", "key" => key, "value" => value, "flag_type" => type} = c,
        _
      ),
      do:
        keys?(c, ~w(type key value flag_type)) and Flags.valid_key?(key) and
          Flags.valid_flag?(%{"type" => type, "value" => value, "player_visible" => false})

  def condition?(_, _), do: false

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
