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
    structural = if valid?(definition, clocks), do: [], else: diagnose(definition, clocks)
    references = AsyncWorlds.Quests.Graph.analyze(definition).errors
    paths = MapSet.new(references, & &1.path)

    Enum.reject(structural, fn {path, _} -> MapSet.member?(paths, path) end) ++
      Enum.map(references, &{&1.path, &1.message})
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
            path <> ".public_summary",
            public_summary?(node),
            "Public activity summary must be valid text (maximum 1000 bytes); blank uses a generic summary"
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

            acc = choice_config_errors(acc, choice, cp, clocks)
            outcomes = field(choice, "outcomes")

            acc =
              if is_map(outcomes) do
                Enum.reduce(outcomes, acc, fn {key, outcome}, acc ->
                  op = cp <> ".outcomes." <> key

                  acc = effect_errors(acc, field(outcome, "effects"), op <> ".effects", clocks)

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

  defp choice_config_errors(errors, choice, path, clocks) do
    mode = field(choice, "mode")
    kinds = if mode == "rolled", do: ~w(success partial failure), else: ["fixed"]

    errors =
      errors
      |> issue(path <> ".mode", mode in ~w(fixed rolled), "Choose fixed or rolled mode")
      |> issue(
        path <> ".outcomes",
        keys?(field(choice, "outcomes"), kinds),
        "Provide exactly #{Enum.join(kinds, ", ")} outcomes"
      )

    errors =
      errors
      |> issue(
        path <> ".eligibility",
        field(choice, "eligibility") in ~w(hidden disabled),
        "Choose hidden or disabled behavior"
      )
      |> condition_errors(field(choice, "conditions"), path <> ".conditions", clocks)

    case mode do
      "rolled" ->
        errors
        |> issue(
          path <> ".dice",
          is_integer(field(choice, "dice")) and field(choice, "dice") in 1..3,
          "Pool must be an integer from 1 to 3 d6"
        )
        |> effect_errors(field(choice, "critical_effects"), path <> ".critical_effects", clocks)

      "fixed" ->
        errors
        |> issue(
          path <> ".dice",
          not Map.has_key?(choice, "dice"),
          "Fixed choices cannot contain a dice pool; use explicit conversion"
        )
        |> issue(
          path <> ".critical_effects",
          not Map.has_key?(choice, "critical_effects"),
          "Fixed choices cannot contain critical bonuses; use explicit conversion"
        )

      _ ->
        errors
    end
  end

  defp condition_errors(errors, conditions, path, clocks) when is_list(conditions) do
    conditions
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {condition, index}, acc ->
      cp = "#{path}[#{index}]"

      acc =
        issue(
          acc,
          cp,
          condition?(condition, clocks),
          "Invalid condition; use a campaign clock threshold or acting-character flag equality"
        )

      condition_field_errors(acc, condition, cp, clocks)
    end)
  end

  defp condition_errors(errors, _, path, _),
    do: issue(errors, path, false, "Provide an AND condition list")

  defp condition_field_errors(acc, %{"type" => "clock_threshold"} = condition, cp, clocks) do
    clock = Map.get(clocks, field(condition, "clock_id"))
    value = field(condition, "value")

    acc
    |> issue(cp <> ".clock_id", clock != nil, "Choose a clock from this campaign")
    |> issue(
      cp <> ".operator",
      field(condition, "operator") in ~w(gte lte),
      "Use at least (gte) or at most (lte)"
    )
    |> issue(
      cp <> ".value",
      is_integer(value) and value >= 0 and (is_nil(clock) or value <= clock.segments),
      "Threshold must be an integer from 0 through the current clock size"
    )
  end

  defp condition_field_errors(acc, %{"type" => "character_flag"} = condition, cp, _) do
    acc
    |> issue(
      cp <> ".key",
      Flags.valid_key?(field(condition, "key")),
      "Enter a valid flag key"
    )
    |> issue(
      cp <> ".value",
      Flags.valid_flag?(%{
        "type" => field(condition, "flag_type"),
        "value" => field(condition, "value"),
        "player_visible" => false
      }),
      "Value must match the explicit boolean, integer or string type"
    )
  end

  defp condition_field_errors(acc, _, _, _), do: acc

  defp effect_errors(errors, effects, path, clocks) when is_list(effects) do
    Enum.with_index(effects)
    |> Enum.reduce(errors, fn {effect, index}, acc ->
      ep = "#{path}[#{index}]"

      acc =
        issue(
          acc,
          ep,
          effect?(effect, clocks),
          "Invalid typed effect; check fields and campaign references"
        )

      case field(effect, "type") do
        "clock_delta" ->
          acc
          |> issue(
            ep <> ".clock_id",
            is_integer(field(effect, "clock_id")) and
              Map.has_key?(clocks, field(effect, "clock_id")),
            "Choose a clock from this campaign"
          )
          |> issue(
            ep <> ".delta",
            is_integer(field(effect, "delta")) and
              field(effect, "delta") in -1_000_000..1_000_000,
            "Delta must be an integer from -1000000 to 1000000"
          )

        "set_flag" ->
          acc
          |> issue(
            ep <> ".key",
            Flags.valid_key?(field(effect, "key")),
            "Flag key must begin with a lowercase letter; use lowercase letters, digits or underscores (maximum 64 bytes)"
          )
          |> issue(
            ep <> ".flag",
            Flags.valid_flag?(field(effect, "flag")),
            "Flag needs a typed boolean, integer or string value and boolean visibility"
          )

        "clear_flag" ->
          issue(
            acc,
            ep <> ".key",
            Flags.valid_key?(field(effect, "key")),
            "Enter a valid flag key"
          )

        _ ->
          issue(
            acc,
            ep <> ".type",
            false,
            "Supported effects: clock_delta, set_flag, clear_flag (resources deferred)"
          )
      end
    end)
  end

  defp effect_errors(errors, _, path, _),
    do: issue(errors, path, false, "Provide an ordered effect list")

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

  @doc "Optional public-only node text. Missing or blank summaries use a generic projection."
  def public_summary?(node) when is_map(node) do
    case Map.fetch(node, "public_summary") do
      :error ->
        true

      {:ok, text} ->
        is_binary(text) and String.valid?(text) and byte_size(text) <= 1000 and
          not String.contains?(text, <<0>>)
    end
  end

  def public_summary?(_), do: false

  defp node_shape?(node) do
    is_map(node) and not is_struct(node) and
      keys?(Map.drop(node, ["public_summary"]), ~w(id text ending choices)) and
      public_summary?(node) and id?(node["id"]) and text?(node["text"]) and
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
