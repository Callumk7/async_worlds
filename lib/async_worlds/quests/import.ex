defmodule AsyncWorlds.Quests.Import do
  @moduledoc "Version 1 JSON decoding and path validation; persistence belongs to Quests."
  alias AsyncWorlds.Quests.Definition
  alias AsyncWorlds.Characters.Flags

  def decode(json, clocks, bindings) do
    try do
      doc =
        case Jason.decode(json, objects: :ordered_objects) do
          {:ok, value} -> plain(value, "$")
          {:error, error} -> invalid!("$", Exception.message(error))
        end

      keys!(doc, ~w(version quests), "$")
      check!(doc["version"] === 1, "$.version", "expected schema version 1")
      quests = list!(doc["quests"], "$.quests", true)
      unique!(quests, "content_id", "$.quests")

      result =
        each(quests, "$.quests", fn quest, path ->
          keys!(quest, ~w(content_id name definition), path)
          check!(Definition.id?(quest["content_id"]), path <> ".content_id", "invalid stable ID")

          check!(
            Definition.text?(quest["name"]) and byte_size(quest["name"]) <= 200,
            path <> ".name",
            "expected nonempty name, at most 200 bytes"
          )

          definition = definition!(quest["definition"], clocks, bindings, path <> ".definition")
          Map.put(quest, "definition", definition)
        end)

      {:ok, result}
    catch
      {:invalid, path, message} -> {:error, [%{path: path, message: message}]}
    end
  end

  defp plain(%Jason.OrderedObject{values: pairs}, path) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      check!(not Map.has_key?(acc, key), path <> "." <> key, "duplicate object field")
      Map.put(acc, key, plain(value, path <> "." <> key))
    end)
  end

  defp plain(list, path) when is_list(list), do: each(list, path, &plain/2)
  defp plain(value, _), do: value

  defp definition!(d, clocks, bindings, p) do
    keys!(d, ~w(start_node nodes), p)
    nodes = list!(d["nodes"], p <> ".nodes", true)
    unique!(nodes, "id", p <> ".nodes")
    ids = Enum.map(nodes, fn n -> if is_map(n), do: n["id"] end)

    check!(
      d["start_node"] in ids and Definition.id?(d["start_node"]),
      p <> ".start_node",
      "must reference a node in this quest"
    )

    nodes =
      each(nodes, p <> ".nodes", fn n, np ->
        keys!(n, ~w(id text ending choices), np)
        check!(Definition.id?(n["id"]), np <> ".id", "invalid stable ID")

        check!(
          Definition.text?(n["text"]),
          np <> ".text",
          "expected nonempty text, at most 8000 bytes"
        )

        check!(is_boolean(n["ending"]), np <> ".ending", "expected boolean")
        choices = list!(n["choices"], np <> ".choices")

        check!(
          if(n["ending"], do: choices == [], else: choices != []),
          np <> ".choices",
          "endings require no choices; non-endings require choices"
        )

        Map.put(
          n,
          "choices",
          each(choices, np <> ".choices", &choice!(&1, ids, clocks, bindings, &2))
        )
      end)

    Enum.reduce(Enum.with_index(nodes), MapSet.new(), fn {n, ni}, seen ->
      Enum.reduce(Enum.with_index(n["choices"]), seen, fn {c, ci}, acc ->
        check!(
          not MapSet.member?(acc, c["id"]),
          "#{p}.nodes[#{ni}].choices[#{ci}].id",
          "duplicate choice ID within quest"
        )

        MapSet.put(acc, c["id"])
      end)
    end)

    Map.put(d, "nodes", nodes)
  end

  defp choice!(c, ids, clocks, bindings, p) do
    check!(is_map(c), p, "expected object")
    check!(c["mode"] in ~w(fixed rolled), p <> ".mode", "expected fixed or rolled")
    fields = ~w(id label eligibility conditions mode outcomes)
    keys!(c, fields ++ if(c["mode"] == "rolled", do: ~w(dice critical_effects), else: []), p)
    check!(Definition.id?(c["id"]), p <> ".id", "invalid stable ID")
    check!(Definition.text?(c["label"]), p <> ".label", "expected nonempty text")

    check!(
      c["eligibility"] in ~w(hidden disabled),
      p <> ".eligibility",
      "expected hidden or disabled"
    )

    conditions =
      each(
        list!(c["conditions"], p <> ".conditions"),
        p <> ".conditions",
        &rule!(&1, :condition, clocks, bindings, &2)
      )

    outcomes = c["outcomes"]

    keys!(
      outcomes,
      if(c["mode"] == "fixed", do: ~w(fixed), else: ~w(success partial failure)),
      p <> ".outcomes"
    )

    outcomes =
      Map.new(outcomes, fn {kind, o} ->
        op = p <> ".outcomes." <> kind
        keys!(o, ~w(text next_node effects), op)
        check!(Definition.text?(o["text"]), op <> ".text", "expected nonempty text")
        check!(o["next_node"] in ids, op <> ".next_node", "must reference a node in this quest")
        {kind, Map.put(o, "effects", effects!(o["effects"], clocks, bindings, op <> ".effects"))}
      end)

    c = c |> Map.put("conditions", conditions) |> Map.put("outcomes", outcomes)

    if c["mode"] == "rolled" do
      check!(c["dice"] in [1, 2, 3], p <> ".dice", "expected integer 1–3")

      Map.put(
        c,
        "critical_effects",
        effects!(c["critical_effects"], clocks, bindings, p <> ".critical_effects")
      )
    else
      c
    end
  end

  defp effects!(effects, clocks, bindings, p),
    do: each(list!(effects, p), p, &rule!(&1, :effect, clocks, bindings, &2))

  defp rule!(r, kind, clocks, bindings, p) do
    check!(is_map(r), p, "expected object")

    fields =
      case {kind, r["type"]} do
        {:condition, "clock_threshold"} ->
          ~w(type clock_id operator value)

        {:condition, "character_flag"} ->
          ~w(type key flag_type value)

        {:effect, "clock_delta"} ->
          ~w(type clock_id delta)

        {:effect, "set_flag"} ->
          ~w(type key flag)

        {:effect, "clear_flag"} ->
          ~w(type key)

        _ ->
          invalid!(
            p <> ".type",
            "unsupported #{kind} type (resource mechanics are not supported)"
          )
      end

    keys!(r, fields, p)

    r =
      if "clock_id" in fields do
        id =
          if is_binary(r["clock_id"]), do: Map.get(bindings, r["clock_id"]), else: r["clock_id"]

        check!(
          is_integer(id) and Map.has_key?(clocks, id),
          p <> ".clock_id",
          "unknown clock in this campaign or unbound alias"
        )

        Map.put(r, "clock_id", id)
      else
        r
      end

    if "key" in fields, do: check!(Flags.valid_key?(r["key"]), p <> ".key", "invalid flag key")

    case r["type"] do
      "clock_threshold" ->
        check!(r["operator"] in ~w(gte lte), p <> ".operator", "expected gte or lte")

        check!(
          is_integer(r["value"]) and r["value"] >= 0 and
            r["value"] <= clocks[r["clock_id"]].segments,
          p <> ".value",
          "threshold must be within clock size"
        )

      "clock_delta" ->
        check!(
          is_integer(r["delta"]) and r["delta"] in -1_000_000..1_000_000,
          p <> ".delta",
          "expected integer delta within +/-1000000"
        )

      "set_flag" ->
        keys!(r["flag"], ~w(type value player_visible), p <> ".flag")

        check!(
          is_boolean(r["flag"]["player_visible"]),
          p <> ".flag.player_visible",
          "expected boolean"
        )

        flag!(r["flag"]["type"], r["flag"]["value"], p <> ".flag.type", p <> ".flag.value")

      "character_flag" ->
        flag!(r["flag_type"], r["value"], p <> ".flag_type", p <> ".value")

      "clear_flag" ->
        :ok
    end

    r
  end

  defp flag!(type, value, tp, vp) do
    check!(
      type in ~w(boolean integer string),
      tp,
      "expected boolean, integer or string flag type"
    )

    check!(
      Flags.valid_flag?(%{"type" => type, "value" => value, "player_visible" => false}),
      vp,
      "invalid value for flag type"
    )
  end

  defp keys!(map, fields, p) do
    check!(is_map(map), p, "expected object")
    Enum.each(fields, &check!(Map.has_key?(map, &1), p <> "." <> &1, "required field"))
    Enum.each(Enum.sort(Map.keys(map)) -- fields, &invalid!(p <> "." <> &1, "unknown field"))
  end

  defp list!(list, p, nonempty \\ false) do
    check!(is_list(list), p, "expected array")
    check!(not nonempty or list != [], p, "must not be empty")
    list
  end

  defp unique!(list, key, p) do
    Enum.reduce(Enum.with_index(list), MapSet.new(), fn {item, i}, acc ->
      check!(is_map(item), "#{p}[#{i}]", "expected object")
      id = item[key]
      check!(not MapSet.member?(acc, id), "#{p}[#{i}].#{key}", "duplicate ID")
      MapSet.put(acc, id)
    end)
  end

  defp each(list, path, fun),
    do: list |> Enum.with_index() |> Enum.map(fn {v, i} -> fun.(v, "#{path}[#{i}]") end)

  defp check!(true, _, _), do: :ok
  defp check!(_, path, message), do: invalid!(path, message)
  defp invalid!(path, message), do: throw({:invalid, path, message})
end
