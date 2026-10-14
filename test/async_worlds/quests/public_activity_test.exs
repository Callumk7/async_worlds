defmodule AsyncWorlds.Quests.PublicActivityTest do
  use ExUnit.Case, async: true

  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.Quests.{Authoring, Definition, Import, PublicActivity, Rules}

  defp with_summary(text) do
    update_in(definition(), ["nodes", Access.at(0)], &Map.put(&1, "public_summary", text))
  end

  test "optional summary validates bytes and rejects malformed text with field diagnostics" do
    assert Definition.valid?(definition(), %{})

    for text <- ["", " \n", "Investigating the harbour", String.duplicate("é", 500)] do
      assert Definition.valid?(with_summary(text), %{})
    end

    for text <- [nil, false, 42, [], %{}, <<255>>, "bad\0text", String.duplicate("é", 501)] do
      refute Definition.valid?(with_summary(text), %{})

      assert {"nodes[0].public_summary", _} =
               Enum.find(Definition.errors(with_summary(text), %{}), fn {path, _} ->
                 path == "nodes[0].public_summary"
               end)
    end

    refute Definition.valid?(
             update_in(definition(), ["nodes", Access.at(0)], &Map.put(&1, "public_extra", "x")),
             %{}
           )
  end

  test "public projection exposes only explicitly authored text and decision state" do
    content = with_summary("Investigating suspicious activity")
    projection = PublicActivity.project(content, "hub", :active)

    assert projection == %{
             summary: "Investigating suspicious activity",
             decision_required: true
           }

    # Private narration, choice labels, conditions, effects and hidden flags never enter it.
    assert Map.keys(projection) |> Enum.sort() == [:decision_required, :summary]

    assert PublicActivity.project(definition(), "hub", :active) == %{
             summary: "A quest decision is required.",
             decision_required: true
           }

    for blank <- ["", " \n"],
        do:
          assert(
            PublicActivity.project(with_summary(blank), "hub", :active) ==
              PublicActivity.project(definition(), "hub", :active)
          )

    assert Rules.project(content, %{node_id: "hub", status: :active, flags: %{}, clocks: %{}}) ==
             Rules.project(definition(), %{
               node_id: "hub",
               status: :active,
               flags: %{},
               clocks: %{}
             })
  end

  test "endings, ended paths and unassigned characters explicitly require no decision" do
    generic = %{summary: "No quest decision required.", decision_required: false}
    assert PublicActivity.project(nil, nil, nil) == generic
    assert PublicActivity.project(definition(), "end", :completed) == generic
    assert PublicActivity.project(definition(), "end", :active) == generic
    assert PublicActivity.project(with_summary("Old activity"), "hub", :ended) == generic

    ending =
      update_in(
        definition(),
        ["nodes", Access.at(1)],
        &Map.put(&1, "public_summary", "Resting after the investigation")
      )

    assert PublicActivity.project(ending, "end", :completed) == %{
             summary: "Resting after the investigation",
             decision_required: false
           }
  end

  test "version-one import preserves optional summaries and precise error paths" do
    envelope = fn content ->
      Jason.encode!(%{
        "version" => 1,
        "quests" => [%{"content_id" => "harbor", "name" => "Harbor", "definition" => content}]
      })
    end

    for content <- [definition(), with_summary("Harbour investigation"), with_summary("")] do
      assert {:ok, [%{"definition" => ^content}]} = Import.decode(envelope.(content), %{}, %{})
    end

    for text <- [nil, 123, false, [], "bad\0text", String.duplicate("x", 1001)] do
      assert {:error, [%{path: "$.quests[0].definition.nodes[0].public_summary"}]} =
               Import.decode(envelope.(with_summary(text)), %{}, %{})
    end
  end

  test "summary forms preserve opaque fields, allow clearing and enforce save bounds" do
    content =
      update_in(
        definition(),
        ["nodes", Access.at(0)],
        &Map.put(&1, "opaque", %{"secret" => true})
      )

    work = %{name: "Harbor", definition: content}
    assert Authoring.form_params(work)["node_0_public_summary"] == ""
    edited = Authoring.apply_form(work, %{"node_0_public_summary" => "Public activity"})
    assert Authoring.safe_edit?(content, edited.definition)
    assert hd(edited.definition["nodes"])["opaque"] == %{"secret" => true}
    assert Authoring.form_params(edited)["node_0_public_summary"] == "Public activity"
    assert Authoring.apply_form(edited, %{}).definition == edited.definition
    assert Authoring.apply_form(edited, %{"node_0_public_summary" => []}) == edited
    cleared = Authoring.apply_form(edited, %{"node_0_public_summary" => " "})
    refute Map.has_key?(hd(cleared.definition["nodes"]), "public_summary")
    assert Authoring.safe_edit?(edited.definition, cleared.definition)

    for text <- [<<255>>, "bad\0", String.duplicate("x", 1001), nil, 123] do
      refute Authoring.safe_edit?(definition(), with_summary(text))
    end

    assert Authoring.safe_edit?(definition(), with_summary(String.duplicate("é", 500)))

    assert [{"nodes[0].public_summary", "Maximum 1000 bytes"}] =
             Authoring.persistence_errors(%{
               definition: with_summary(String.duplicate("x", 1001))
             })
  end
end
