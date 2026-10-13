defmodule AsyncWorlds.Quests.Graph do
  @moduledoc "Pure directed graph inspection of incomplete copies. Every outcome is an edge, independent of eligibility."
  alias AsyncWorlds.Quests.Definition

  def analyze(definition) do
    nodes = field(definition, "nodes") |> list()

    vertices =
      Enum.with_index(nodes)
      |> Enum.map(fn {n, i} ->
        %{
          id: field(n, "id"),
          index: i,
          text: field(n, "text"),
          ending: field(n, "ending") == true,
          start: field(n, "id") == field(definition, "start_node")
        }
      end)

    ids = vertices |> Enum.map(& &1.id) |> Enum.filter(&Definition.id?/1) |> MapSet.new()

    edges =
      Enum.with_index(nodes)
      |> Enum.flat_map(fn {n, i} ->
        field(n, "choices")
        |> list()
        |> Enum.with_index()
        |> Enum.flat_map(fn {c, j} ->
          field(c, "outcomes")
          |> object()
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {kind, o} ->
            %{
              source: field(n, "id"),
              destination: field(o, "next_node"),
              node_index: i,
              choice_index: j,
              choice_id: field(c, "id"),
              label: field(c, "label"),
              outcome: kind,
              path: "nodes[#{i}].choices[#{j}].outcomes.#{kind}.next_node"
            }
          end)
        end)
      end)

    start = field(definition, "start_node")

    errors =
      if MapSet.member?(ids, start),
        do: [],
        else: [diagnostic("start_node", "Choose an existing start node", :error, nil, nil)]

    errors =
      errors ++
        Enum.flat_map(edges, fn e ->
          if MapSet.member?(ids, e.destination),
            do: [],
            else: [
              diagnostic(
                e.path,
                "Choose an existing destination (#{inspect(e.destination)})",
                :error,
                e.node_index,
                e.choice_index
              )
            ]
        end)

    reached = visit([start], edges, ids, MapSet.new())

    warnings =
      Enum.flat_map(vertices, fn v ->
        if MapSet.member?(reached, v.id),
          do: [],
          else: [
            diagnostic(
              "nodes[#{v.index}]",
              "Node is unreachable from the start (all outcomes considered)",
              :warning,
              v.index,
              nil
            )
          ]
      end)

    %{nodes: vertices, edges: edges, errors: errors, warnings: warnings}
  end

  def inbound(definition, id), do: Enum.filter(analyze(definition).edges, &(&1.destination == id))

  defp visit([], _, _, seen), do: seen

  defp visit([id | rest], edges, ids, seen) do
    if MapSet.member?(seen, id) or not MapSet.member?(ids, id) do
      visit(rest, edges, ids, seen)
    else
      next = edges |> Enum.filter(&(&1.source == id)) |> Enum.map(& &1.destination)
      visit(next ++ rest, edges, ids, MapSet.put(seen, id))
    end
  end

  defp diagnostic(path, message, severity, node, choice),
    do: %{
      path: path,
      message: message,
      severity: severity,
      node_index: node,
      choice_index: choice
    }

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_, _), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp object(value) when is_map(value), do: value
  defp object(_), do: %{}
end
