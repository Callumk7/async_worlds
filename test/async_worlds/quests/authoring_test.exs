defmodule AsyncWorlds.Quests.AuthoringTest do
  use ExUnit.Case, async: true

  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.Quests.Authoring

  defp draft do
    %{
      "start_node" => "hub",
      "nodes" => [
        %{"id" => "hub", "text" => "", "ending" => false, "choices" => [choice("act", "")]}
      ]
    }
  end

  defp editable_paths do
    [
      {["start_node"], 100},
      {["nodes", Access.at(0), "text"], 8000},
      {["nodes", Access.at(0), "choices", Access.at(0), "label"], 8000},
      {["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "text"], 8000},
      {["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "next_node"], 100}
    ]
  end

  test "text and reference limits are inclusive and count bytes, not characters" do
    old = draft()

    for {path, limit} <- editable_paths(), character <- ["a", "é"] do
      boundary = String.duplicate(character, div(limit, byte_size(character)))
      assert byte_size(boundary) == limit
      assert Authoring.safe_edit?(old, put_in(old, path, boundary))
      refute Authoring.safe_edit?(old, put_in(old, path, boundary <> "a"))
    end
  end

  test "node and choice counts allow 100 but not 101, and nodes cannot be empty" do
    old = draft()
    [node] = old["nodes"]
    nodes = [node | Enum.map(1..99, fn _ -> Authoring.new_node() end)]
    bounded = Map.put(old, "nodes", nodes)
    assert Authoring.safe_edit?(old, bounded)
    refute Authoring.safe_edit?(old, Map.put(bounded, "nodes", nodes ++ [Authoring.new_node()]))
    refute Authoring.safe_edit?(old, Map.put(old, "nodes", []))

    choices = node["choices"] ++ Enum.map(1..99, fn _ -> Authoring.new_choice() end)
    path = ["nodes", Access.at(0), "choices"]
    assert Authoring.safe_edit?(old, put_in(old, path, choices))
    refute Authoring.safe_edit?(old, put_in(old, path, choices ++ [Authoring.new_choice()]))
  end

  test "malformed definitions and nested shapes return false" do
    old = draft()

    for invalid <- [nil, false, 1, "definition", [], %{}, %{nodes: []}] do
      refute Authoring.safe_edit?(old, invalid)
    end

    paths = [
      ["start_node"],
      ["nodes"],
      ["nodes", Access.at(0)],
      ["nodes", Access.at(0), "text"],
      ["nodes", Access.at(0), "ending"],
      ["nodes", Access.at(0), "choices"],
      ["nodes", Access.at(0), "choices", Access.at(0)],
      ["nodes", Access.at(0), "choices", Access.at(0), "label"],
      ["nodes", Access.at(0), "choices", Access.at(0), "outcomes"],
      ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed"],
      ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "text"],
      ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "next_node"]
    ]

    for path <- paths, invalid <- [nil, 123, :invalid, [], %{}] do
      refute Authoring.safe_edit?(old, put_in(old, path, invalid))
    end

    for path <- [Enum.at(paths, 2), Enum.at(paths, 6), Enum.at(paths, 9)] do
      refute Authoring.safe_edit?(old, put_in(old, path, "not a map"))
    end

    for {path, _} <- editable_paths() do
      missing = pop_in(old, path) |> elem(1)
      refute Authoring.safe_edit?(old, missing)
    end

    refute Authoring.safe_edit?(old, put_in(old, ["nodes", Access.at(0), "ending"], "false"))
  end

  test "invalid UTF8 and NUL are rejected in editable fields and opaque data" do
    old = draft()

    for invalid <- [<<255>>, "bad" <> <<0>>] do
      for {path, _} <- editable_paths() do
        refute Authoring.safe_edit?(old, put_in(old, path, invalid))
      end

      for metadata <- [%{"nested" => [invalid]}, %{invalid => "value"}] do
        imported = Map.put(old, "metadata", metadata)
        refute Authoring.safe_edit?(imported, imported)
      end
    end

    for unsupported <- [:atom, {"tuple"}, self(), MapSet.new(["struct"])] do
      imported = Map.put(old, "metadata", unsupported)
      refute Authoring.safe_edit?(imported, imported)
    end
  end

  test "incomplete drafts, empty choices and imported empty outcomes remain safe" do
    old = draft()

    empty = Enum.reduce(editable_paths(), old, fn {path, _}, acc -> put_in(acc, path, "") end)
    assert Authoring.safe_edit?(old, empty)
    assert Authoring.safe_edit?(old, Map.put(old, "start_node", "missing"))

    new = Authoring.new_definition()
    assert Authoring.safe_edit?(new, new)

    opaque = put_in(old, ["nodes", Access.at(0), "choices", Access.at(0), "mode"], "imported")
    opaque = put_in(opaque, ["nodes", Access.at(0), "choices", Access.at(0), "outcomes"], %{})
    assert Authoring.safe_edit?(opaque, opaque)
  end

  test "all imported outcomes are bounded without losing opaque fields" do
    for imported_choice <- [rolled(), choice("effect", "hub", [%{"type" => "custom"}])] do
      old = replace_choice(definition(), imported_choice)
      old = Map.put(old, "metadata", %{"nested" => [nil, true, 42, 1.5, "é"]})
      assert Authoring.safe_edit?(old, old)
      assert Authoring.safe_edit?(old, put_in(old, ["nodes", Access.at(0), "text"], "Edited"))

      for key <- Map.keys(imported_choice["outcomes"]),
          {field, limit} <- [{"text", 8000}, {"next_node", 100}] do
        path = ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", key, field]
        bounded = put_in(old, path, String.duplicate("a", limit))
        assert Authoring.safe_edit?(bounded, bounded)
        oversized = put_in(old, path, String.duplicate("a", limit + 1))
        refute Authoring.safe_edit?(oversized, oversized)
        refute Authoring.safe_edit?(old, bounded)
      end

      for invalid <- [nil, [], "outcome", %{}] do
        malformed =
          put_in(
            old,
            ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "extra"],
            invalid
          )

        refute Authoring.safe_edit?(malformed, malformed)
      end

      refute Authoring.safe_edit?(old, put_in(old, ["nodes", Access.at(0), "ending"], true))
    end
  end

  test "stable IDs, order, deletions and unmodeled fields remain protected" do
    old = draft()
    path = ["nodes", Access.at(0), "choices", Access.at(0)]

    refute Authoring.safe_edit?(old, put_in(old, path ++ ["id"], "forged"))
    refute Authoring.safe_edit?(old, put_in(old, path ++ ["conditions"], [%{"type" => "custom"}]))
    refute Authoring.safe_edit?(old, put_in(old, path ++ ["outcomes", "fixed", "effects"], [1]))
    refute Authoring.safe_edit?(old, put_in(old, ["nodes", Access.at(0), "id"], "forged"))
    refute Authoring.safe_edit?(old, put_in(old, ["nodes", Access.at(0), "choices"], []))
    refute Authoring.safe_edit?(old, Map.put(old, "extra", true))

    imported = definition()
    refute Authoring.safe_edit?(imported, Map.update!(imported, "nodes", &Enum.reverse/1))
    refute Authoring.safe_edit?(imported, Map.update!(imported, "nodes", &Enum.take(&1, 1)))

    reversed =
      update_in(imported, ["nodes", Access.at(0), "choices"], &Enum.reverse/1)

    refute Authoring.safe_edit?(imported, reversed)
  end
end
