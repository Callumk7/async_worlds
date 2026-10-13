defmodule AsyncWorlds.Quests.Authoring do
  @moduledoc "Fixed form vocabulary. IDs are allocated once; unsupported imported choices are opaque."

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
    choice["mode"] == "fixed" and choice["conditions"] == [] and
      get_in(choice, ["outcomes", "fixed", "effects"]) == []
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

              outcome = choice["outcomes"]["fixed"]

              outcome =
                outcome
                |> Map.put("text", binary_param(params, cp <> "_text", outcome["text"]))
                |> Map.put(
                  "next_node",
                  binary_param(params, cp <> "_destination", outcome["next_node"])
                )

              put_in(choice, ["outcomes", "fixed"], outcome)
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

            acc
            |> Map.put(cp <> "_label", choice["label"])
            |> Map.put(cp <> "_text", choice["outcomes"]["fixed"]["text"])
            |> Map.put(cp <> "_destination", choice["outcomes"]["fixed"]["next_node"])
          else
            acc
          end
        end)
      end
    )
  end

  @doc "Existing IDs/order and unmodeled fields cannot change, even through forged form payloads."
  def safe_edit?(old, new) do
    is_map(new) and bounded_definition?(new) and
      Map.keys(new) |> Enum.sort() == Enum.sort(Map.keys(old)) and
      is_list(new["nodes"]) and length(new["nodes"]) >= length(old["nodes"]) and
      Enum.zip(old["nodes"], new["nodes"]) |> Enum.all?(fn {a, b} -> safe_node?(a, b) end) and
      Enum.drop(new["nodes"], length(old["nodes"])) |> Enum.all?(&fresh_node?/1)
  rescue
    _ -> false
  end

  defp safe_node?(a, b) do
    Map.drop(a, ["text", "ending", "choices"]) == Map.drop(b, ["text", "ending", "choices"]) and
      (Enum.all?(a["choices"], &editable?/1) or a["ending"] == b["ending"]) and
      length(b["choices"]) >= length(a["choices"]) and
      Enum.zip(a["choices"], b["choices"])
      |> Enum.all?(fn {x, y} ->
        if editable?(x) do
          Map.drop(x, ["label", "outcomes"]) == Map.drop(y, ["label", "outcomes"]) and
            Map.keys(y["outcomes"]) == ["fixed"] and
            Map.drop(x["outcomes"]["fixed"], ["text", "next_node"]) ==
              Map.drop(y["outcomes"]["fixed"], ["text", "next_node"])
        else
          x == y
        end
      end) and Enum.drop(b["choices"], length(a["choices"])) |> Enum.all?(&fresh_choice?/1)
  end

  defp fresh_node?(node),
    do:
      Map.keys(node) |> Enum.sort() == Enum.sort(~w(id text ending choices)) and
        AsyncWorlds.Quests.Definition.id?(node["id"]) and is_list(node["choices"]) and
        Enum.all?(node["choices"], &fresh_choice?/1)

  defp fresh_choice?(choice),
    do:
      Map.drop(choice, ["id", "label", "outcomes"]) ==
        Map.drop(new_choice(), ["id", "label", "outcomes"]) and
        AsyncWorlds.Quests.Definition.id?(choice["id"]) and
        Map.keys(choice["outcomes"]) == ["fixed"] and
        Map.drop(choice["outcomes"]["fixed"], ["text", "next_node"]) == %{"effects" => []}

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

  defp id(prefix), do: prefix <> "_" <> Ecto.UUID.generate()
end
