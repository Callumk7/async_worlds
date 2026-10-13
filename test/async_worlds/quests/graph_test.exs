defmodule AsyncWorlds.Quests.GraphTest do
  use ExUnit.Case, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.Quests.{Definition, Graph}

  test "all rolled branches, cycles, self loops and disconnected endings" do
    d = replace_choice(definition(), rolled())
    graph = Graph.analyze(d)
    assert length(graph.edges) == 3
    assert Enum.any?(graph.edges, &(&1.source == &1.destination))
    assert graph.errors == []
    assert graph.warnings == []

    cyclic =
      put_in(
        d,
        ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "success", "next_node"],
        "hub"
      )

    cyclic =
      put_in(
        cyclic,
        ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "failure", "next_node"],
        "hub"
      )

    assert [%{path: "nodes[1]", severity: :warning}] = Graph.analyze(cyclic).warnings
    assert Definition.valid?(cyclic, %{})
  end

  test "broken references retain exact source paths and block shared validation" do
    d = replace_choice(definition(), rolled())

    d =
      put_in(
        d,
        ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "partial", "next_node"],
        "gone"
      )

    d = Map.put(d, "start_node", "gone")
    graph = Graph.analyze(d)

    assert Enum.map(graph.errors, & &1.path) == [
             "start_node",
             "nodes[0].choices[0].outcomes.partial.next_node"
           ]

    assert Enum.any?(Definition.errors(d, %{}), fn {p, _} ->
             p == "nodes[0].choices[0].outcomes.partial.next_node"
           end)

    assert Enum.any?(graph.edges, &(&1.destination == "gone"))
    assert length(Graph.inbound(d, "end")) == 1
  end

  test "multi-node cycles, multiple inbound and condition-independent reachability" do
    d = definition()
    [hub, ending] = d["nodes"]

    middle = %{
      "id" => "middle",
      "text" => "Middle",
      "ending" => false,
      "choices" => [choice("back", "hub"), choice("stop", "end")]
    }

    branching = Map.put(hub, "choices", [choice("via", "middle"), choice("direct", "end")])

    branching =
      put_in(branching, ["choices", Access.at(0), "conditions"], [
        %{
          "type" => "character_flag",
          "key" => "impossible",
          "flag_type" => "boolean",
          "value" => true
        }
      ])

    d = Map.put(d, "nodes", [branching, middle, ending])
    assert Graph.analyze(d).warnings == []
    assert length(Graph.inbound(d, "end")) == 2
    assert Definition.valid?(d, %{})

    cycle =
      Map.put(d, "nodes", [
        Map.put(branching, "choices", [choice("via", "middle")]),
        Map.put(middle, "choices", [choice("back", "hub")])
      ])

    assert Graph.analyze(cycle).errors == []
    assert Graph.analyze(cycle).warnings == []
    assert Definition.valid?(cycle, %{})
  end

  test "incomplete and malformed working copies never crash" do
    for d <- [
          nil,
          %{},
          %{"nodes" => [nil, %{}, %{"choices" => [nil, %{"outcomes" => %{"failure" => nil}}]}]}
        ] do
      assert %{nodes: _, edges: _, errors: _, warnings: _} = Graph.analyze(d)
    end
  end
end
