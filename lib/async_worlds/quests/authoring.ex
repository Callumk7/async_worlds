defmodule AsyncWorlds.Quests.Authoring do
  @moduledoc "Fixed and rolled form vocabulary with stable identities and opaque-field preservation."
  alias AsyncWorlds.Quests.EffectAuthoring

  def new_definition do
    node = new_node()
    %{"start_node" => node["id"], "nodes" => [node]}
  end

  def new_node do
    %{"id" => id("node"), "text" => "", "ending" => false, "choices" => []}
  end

  def new_choice do
    %{
      "id" => id("choice"),
      "label" => "",
      "mode" => "fixed",
      "eligibility" => "disabled",
      "conditions" => [],
      "outcomes" => %{"fixed" => %{"text" => "", "next_node" => "", "effects" => []}}
    }
  end

  def editable?(choice) do
    choice["mode"] in ["fixed", "rolled"] and is_map(choice["outcomes"]) and
      Enum.sort(Map.keys(choice["outcomes"])) == Enum.sort(outcome_kinds(choice))
  end

  # Never rebuild imported content from a lossy UI projection.
  def apply_form(work, params) do
    definition = work.definition

    nodes =
      Enum.with_index(definition["nodes"])
      |> Enum.map(fn {node, i} ->
        prefix = "node_#{i}"
        node = Map.put(node, "text", binary_param(params, prefix <> "_text", node["text"]))

        node =
          if Enum.all?(node["choices"], &editable?/1),
            do:
              Map.put(
                node,
                "ending",
                binary_param(params, prefix <> "_ending", to_string(node["ending"])) == "true"
              ),
            else: node

        choices =
          Enum.with_index(node["choices"])
          |> Enum.map(fn {choice, j} ->
            if editable?(choice) do
              cp = prefix <> "_choice_#{j}"

              choice =
                Map.put(choice, "label", binary_param(params, cp <> "_label", choice["label"]))

              outcomes =
                Map.new(choice["outcomes"], fn {kind, outcome} ->
                  op = outcome_prefix(cp, kind)

                  {kind,
                   outcome
                   |> Map.put("text", binary_param(params, op <> "_text", outcome["text"]))
                   |> Map.put(
                     "next_node",
                     binary_param(params, op <> "_destination", outcome["next_node"])
                   )}
                end)

              choice = Map.put(choice, "outcomes", outcomes)

              if choice["mode"] == "rolled" do
                effects =
                  Enum.with_index(choice["critical_effects"])
                  |> Enum.map(fn {effect, k} ->
                    EffectAuthoring.apply_form(effect, params, cp <> "_critical_#{k}")
                  end)

                choice
                |> Map.put(
                  "dice",
                  EffectAuthoring.integer(
                    binary_param(params, cp <> "_dice", to_string(choice["dice"]))
                  )
                )
                |> Map.put("critical_effects", effects)
              else
                choice
              end
            else
              choice
            end
          end)

        Map.put(node, "choices", choices)
      end)

    %{
      work
      | name: binary_param(params, "name", work.name),
        content_id: binary_param(params, "content_id", work.content_id),
        definition: %{
          definition
          | "nodes" => nodes,
            "start_node" => binary_param(params, "start_node", definition["start_node"])
        }
    }
  end

  def form_params(work) do
    Enum.with_index(work.definition["nodes"])
    |> Enum.reduce(
      %{
        "name" => work.name,
        "content_id" => work.content_id,
        "start_node" => work.definition["start_node"]
      },
      fn {node, i}, acc ->
        prefix = "node_#{i}"

        acc =
          acc
          |> Map.put(prefix <> "_text", node["text"])
          |> Map.put(prefix <> "_ending", to_string(node["ending"]))

        Enum.with_index(node["choices"])
        |> Enum.reduce(acc, fn {choice, j}, acc ->
          if editable?(choice) do
            cp = prefix <> "_choice_#{j}"

            acc = Map.put(acc, cp <> "_label", choice["label"])

            acc =
              Enum.reduce(choice["outcomes"], acc, fn {kind, outcome}, acc ->
                op = outcome_prefix(cp, kind)

                acc
                |> Map.put(op <> "_text", outcome["text"])
                |> Map.put(op <> "_destination", outcome["next_node"])
              end)

            if choice["mode"] == "rolled" do
              Enum.with_index(choice["critical_effects"])
              |> Enum.reduce(Map.put(acc, cp <> "_dice", to_string(choice["dice"])), fn {effect,
                                                                                         k},
                                                                                        acc ->
                Enum.reduce(EffectAuthoring.form_params(effect), acc, fn {key, value}, acc ->
                  Map.put(acc, cp <> "_critical_#{k}_" <> key, value)
                end)
              end)
            else
              acc
            end
          else
            acc
          end
        end)
      end
    )
  end

  def outcome_kinds(%{"mode" => "rolled"}), do: ~w(success partial failure)
  def outcome_kinds(_), do: ["fixed"]
  def outcome_prefix(prefix, "fixed"), do: prefix
  def outcome_prefix(prefix, kind), do: prefix <> "_" <> kind

  def convertible?(choice) do
    editable?(choice) and
      Enum.all?(choice["outcomes"], fn {_, o} ->
        Map.keys(o) |> Enum.sort() == Enum.sort(~w(text next_node effects))
      end) and
      conversion_fields_safe?(choice)
  end

  defp conversion_fields_safe?(%{"mode" => "fixed"} = choice) do
    not Map.has_key?(choice, "dice") and not Map.has_key?(choice, "critical_effects")
  end

  defp conversion_fields_safe?(%{"mode" => "rolled"} = choice) do
    # Conversion must not provide a back door for discarding opaque imported fields.
    Enum.all?(choice["critical_effects"], &EffectAuthoring.editable?/1) and
      Enum.all?(~w(partial failure), fn kind ->
        Enum.all?(choice["outcomes"][kind]["effects"], &EffectAuthoring.editable?/1)
      end)
  end

  def convert(choice, mode) when mode in ["fixed", "rolled"] do
    cond do
      not convertible?(choice) or choice["mode"] == mode ->
        choice

      mode == "rolled" ->
        outcome = choice["outcomes"]["fixed"]

        choice
        |> Map.put("mode", mode)
        |> Map.put("dice", 1)
        |> Map.put("critical_effects", [])
        |> Map.put("outcomes", %{
          "success" => outcome,
          "partial" => %{"text" => "", "next_node" => "", "effects" => []},
          "failure" => %{"text" => "", "next_node" => "", "effects" => []}
        })

      true ->
        choice
        |> Map.put("mode", mode)
        |> Map.drop(["dice", "critical_effects"])
        |> Map.put("outcomes", %{"fixed" => choice["outcomes"]["success"]})
    end
  end

  def update_choice(definition, node_id, choice_id, fun) do
    Map.update!(definition, "nodes", fn nodes ->
      Enum.map(nodes, fn node ->
        if node["id"] == node_id,
          do:
            Map.update!(node, "choices", fn choices ->
              Enum.map(choices, fn choice ->
                if choice["id"] == choice_id, do: fun.(choice), else: choice
              end)
            end),
          else: node
      end)
    end)
  end

  defp safe_choice?(old, new) do
    if editable?(old) and editable?(new) do
      same_mode? = old["mode"] == new["mode"]
      base = if same_mode?, do: old, else: convert(old, new["mode"])

      opaque =
        ["label", "outcomes"] ++
          if(base["mode"] == "rolled", do: ["dice", "critical_effects"], else: [])

      Map.drop(base, opaque) == Map.drop(new, opaque) and
        Enum.all?(new["outcomes"], fn {kind, outcome} ->
          previous = base["outcomes"][kind]

          is_map(previous) and
            Map.drop(previous, ["text", "next_node"]) == Map.drop(outcome, ["text", "next_node"])
        end) and
        (new["mode"] != "rolled" or
           ((is_integer(new["dice"]) or is_binary(new["dice"])) and
              EffectAuthoring.safe_edit?(base["critical_effects"], new["critical_effects"])))
    else
      old == new
    end
  end

  @doc "Match by stable identity, permitting removal/reordering while preserving retained opaque fields."
  def safe_edit?(old, new) do
    is_map(new) and bounded_definition?(new) and
      Map.drop(new, ["start_node", "nodes"]) == Map.drop(old, ["start_node", "nodes"]) and
      unique_ids?(new["nodes"]) and unique_ids?(Enum.flat_map(new["nodes"], & &1["choices"])) and
      retained_parents?(old["nodes"], new["nodes"]) and
      safe_collection?(old["nodes"], new["nodes"], &safe_node?/2, &fresh_node?/1)
  rescue
    _ -> false
  end

  defp safe_node?(a, b) do
    Map.drop(a, ["text", "ending", "choices"]) == Map.drop(b, ["text", "ending", "choices"]) and
      (Enum.all?(b["choices"], &editable?/1) or a["ending"] == b["ending"]) and
      safe_collection?(
        a["choices"],
        b["choices"],
        &safe_choice?/2,
        &fresh_choice?/1
      )
  end

  defp retained_parents?(old, new) do
    owners = for node <- old, choice <- node["choices"], into: %{}, do: {choice["id"], node["id"]}

    Enum.all?(new, fn node ->
      Enum.all?(node["choices"], fn choice ->
        not Map.has_key?(owners, choice["id"]) or
          owners[choice["id"]] == node["id"]
      end)
    end)
  end

  defp unique_ids?(items) do
    ids = Enum.map(items, & &1["id"])
    Enum.all?(ids, &AsyncWorlds.Quests.Definition.id?/1) and length(ids) == length(Enum.uniq(ids))
  end

  defp safe_collection?(old, new, retained?, fresh?) do
    existing = Map.new(old, &{&1["id"], &1})

    Enum.all?(new, fn item ->
      case Map.fetch(existing, item["id"]) do
        {:ok, previous} -> retained?.(previous, item)
        :error -> fresh?.(item)
      end
    end)
  end

  @doc "Local structural operations use stable IDs, never browser list offsets."
  def restructure(definition, action, node_id, choice_id \\ nil) do
    nodes = definition["nodes"]

    nodes =
      if choice_id do
        Enum.map(nodes, fn node ->
          if node["id"] == node_id,
            do: Map.update!(node, "choices", &reorder(&1, action, choice_id)),
            else: node
        end)
      else
        if action == "remove" and length(nodes) == 1,
          do: nodes,
          else: reorder(nodes, action, node_id)
      end

    Map.put(definition, "nodes", nodes)
  end

  defp reorder(items, "remove", id), do: Enum.reject(items, &(&1["id"] == id))

  defp reorder(items, action, id) when action in ["up", "down"] do
    index = Enum.find_index(items, &(&1["id"] == id))
    target = if index, do: index + if(action == "up", do: -1, else: 1)

    if index && target >= 0 && target < length(items) do
      item = Enum.at(items, index)
      items |> List.delete_at(index) |> List.insert_at(target, item)
    else
      items
    end
  end

  defp reorder(items, _, _), do: items

  defp fresh_node?(node),
    do:
      Map.keys(node) |> Enum.sort() == Enum.sort(~w(id text ending choices)) and
        allocated_id?(node["id"], "node") and is_list(node["choices"]) and
        Enum.all?(node["choices"], &fresh_choice?/1)

  defp fresh_choice?(choice),
    do:
      allocated_id?(choice["id"], "choice") and
        safe_choice?(%{new_choice() | "id" => choice["id"]}, choice)

  @doc "Persistence text diagnostics, separate from structural edit and release validation."
  def persistence_errors(attrs) when is_map(attrs) do
    text_errors(attrs[:name], "name", 8000) ++
      text_errors(attrs[:content_id], "content_id", 8000) ++
      json_text_errors(attrs[:definition], "")
  end

  def persistence_errors(_), do: []

  defp text_errors(value, path, limit) when is_binary(value) do
    cond do
      not String.valid?(value) -> [{path, "Must be valid UTF-8 text"}]
      String.contains?(value, <<0>>) -> [{path, "Must not contain NUL characters"}]
      limit != nil and byte_size(value) > limit -> [{path, "Maximum #{limit} bytes"}]
      true -> []
    end
  end

  defp text_errors(_, _, _), do: []

  defp json_text_errors(value, path) when is_map(value) and not is_struct(value) do
    Enum.flat_map(value, fn {key, item} ->
      key_errors = text_errors(key, path <> ".<key>", nil)
      field = if is_binary(key) and key_errors == [], do: key, else: "<key>"
      child_path = if path == "", do: field, else: path <> "." <> field

      limit =
        case key do
          key when key in ["text", "label"] -> 8000
          key when key in ["start_node", "next_node"] -> 100
          _ -> nil
        end

      key_errors ++
        if is_binary(item),
          do: text_errors(item, child_path, limit),
          else: json_text_errors(item, child_path)
    end)
  end

  defp json_text_errors(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> json_text_errors(item, "#{path}[#{index}]") end)
  end

  defp json_text_errors(value, path) when is_binary(value), do: text_errors(value, path, nil)
  defp json_text_errors(_, _), do: []

  @doc "Allow incomplete text, but reject values PostgreSQL text/JSONB cannot persist."
  def persistence_safe?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  def persistence_safe?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> persistence_safe?(key) and persistence_safe?(item) end)

  def persistence_safe?(value) when is_list(value), do: Enum.all?(value, &persistence_safe?/1)

  def persistence_safe?(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: true

  def persistence_safe?(_), do: false

  defp bounded_definition?(%{"start_node" => start_node, "nodes" => nodes} = definition)
       when is_binary(start_node) and byte_size(start_node) <= 100 and is_list(nodes) and
              length(nodes) in 1..100 do
    persistence_safe?(definition) and Enum.all?(nodes, &bounded_node?/1)
  end

  defp bounded_definition?(_), do: false

  defp bounded_node?(%{"text" => text, "ending" => ending, "choices" => choices})
       when is_binary(text) and byte_size(text) <= 8000 and is_boolean(ending) and
              is_list(choices) and length(choices) <= 100 do
    Enum.all?(choices, &bounded_choice?/1)
  end

  defp bounded_node?(_), do: false

  defp bounded_choice?(%{"label" => label, "outcomes" => outcomes})
       when is_binary(label) and byte_size(label) <= 8000 and is_map(outcomes) do
    Enum.all?(outcomes, fn {_, outcome} -> bounded_outcome?(outcome) end)
  end

  defp bounded_choice?(_), do: false

  defp bounded_outcome?(%{"text" => text, "next_node" => next_node})
       when is_binary(text) and byte_size(text) <= 8000 and is_binary(next_node) and
              byte_size(next_node) <= 100,
       do: true

  defp bounded_outcome?(_), do: false

  defp binary_param(params, key, default) do
    case Map.get(params, key, default) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp allocated_id?(id, prefix) when is_binary(id) do
    case String.split(id, prefix <> "_", parts: 2) do
      ["", uuid] -> match?({:ok, _}, Ecto.UUID.cast(uuid))
      _ -> false
    end
  end

  defp allocated_id?(_, _), do: false

  defp id(prefix), do: prefix <> "_" <> Ecto.UUID.generate()
end
