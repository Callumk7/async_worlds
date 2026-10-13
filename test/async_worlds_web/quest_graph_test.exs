defmodule AsyncWorldsWeb.QuestGraphTest do
  use ExUnit.Case, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorldsWeb.QuestGraph

  test "content identity diagnostics target the read-only identity display" do
    assert QuestGraph.target("content_id", definition()) == "quest-identity"
  end

  test "fixed label diagnostics target the label input" do
    assert QuestGraph.target(
             "nodes[0].choices[0].label",
             replace_choice(definition(), choice("simple", "end"))
           ) == "choice-0-0-label"
  end

  test "fixed outcome text diagnostics target the outcome input" do
    assert QuestGraph.target(
             "nodes[0].choices[0].outcomes.fixed.text",
             replace_choice(definition(), choice("simple", "end"))
           ) ==
             "choice-0-0-text"
  end

  test "node choice consistency diagnostics target the explicit node type" do
    assert QuestGraph.target("nodes[0].choices", definition()) == "node-0-ending"
    assert QuestGraph.target("nodes[0].ending", definition()) == "node-0-ending"
  end

  test "rolled diagnostics target each branch and pool" do
    imported = replace_choice(definition(), rolled())
    assert QuestGraph.target("nodes[0].choices[0].dice", imported) == "choice-0-0-dice"

    assert QuestGraph.target("nodes[0].choices[0].outcomes.partial.text", imported) ==
             "choice-0-0_partial-text"

    assert QuestGraph.target("nodes[0].choices[0].outcomes.failure.next_node", imported) ==
             "choice-0-0_failure-destination"
  end

  test "opaque diagnostics retain focusable read-only fallbacks" do
    imported = replace_choice(definition(), Map.put(rolled(), "mode", "unsupported"))
    assert QuestGraph.target("nodes[0].choices[0].label", imported) == "editor-choice-0-0"

    assert QuestGraph.target("nodes[0].choices[0].outcomes.partial.text", imported) ==
             "editor-choice-0-0"

    assert QuestGraph.target("nodes[0].choices[0].outcomes.partial.next_node", imported) ==
             "choice-0-0-destination"
  end
end
