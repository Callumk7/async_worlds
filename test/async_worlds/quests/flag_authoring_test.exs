defmodule AsyncWorlds.Quests.FlagAuthoringTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Quests.{Authoring, ConditionAuthoring, EffectAuthoring, Rules, Definition}
  import AsyncWorlds.QuestFixtures

  test "absent flags, strict type equality, AND and safe hidden/disabled projections" do
    condition = %{
      "type" => "character_flag",
      "key" => "secret",
      "flag_type" => "boolean",
      "value" => false
    }

    hidden =
      choice("hidden_name", "hub")
      |> Map.put("conditions", [condition])
      |> Map.put("eligibility", "hidden")

    disabled = %{
      hidden
      | "id" => "disabled_name",
        "label" => "Disabled",
        "eligibility" => "disabled"
    }

    d = definition() |> put_in(["nodes", Access.at(0), "choices"], [hidden, disabled])
    state = %{node_id: "hub", status: :active, flags: %{}, clocks: %{}}

    assert Rules.project(d, state).choices == [
             %{
               id: "disabled_name",
               label: "Disabled",
               enabled: false,
               hint: "Not available right now."
             }
           ]

    assert {:error, :invalid_transition} = Rules.transition(d, state, "hidden_name")

    for {type, value} <- [{"string", "false"}, {"integer", 0}, {"boolean", true}] do
      refute Rules.eligible?(
               hidden,
               %{"secret" => %{"type" => type, "value" => value, "player_visible" => false}},
               %{}
             )
    end

    flags = %{"secret" => flag(false)}
    assert Rules.eligible?(hidden, flags, %{})
    and_choice = Map.put(hidden, "conditions", [condition, %{condition | "key" => "other"}])
    refute Rules.eligible?(and_choice, flags, %{})
    assert Rules.eligible?(and_choice, Map.put(flags, "other", flag(false)), %{})
    assert length(Rules.project(d, %{state | flags: flags}).choices) == 2
  end

  test "all ordered outcome and critical lists use typed values and retain opaque fields and CRLF" do
    opaque = %{"type" => "resource_gain", "target" => "party", "amount" => 2}

    imported_condition = %{
      "type" => "clock_threshold",
      "clock_id" => 1,
      "operator" => "gte",
      "value" => 2
    }

    string = %{
      "type" => "set_flag",
      "key" => "phrase",
      "flag" => %{
        "type" => "string",
        "value" => "quoted \"text\"\r\nnext\rline",
        "player_visible" => false
      }
    }

    c = rolled() |> Map.put("conditions", [imported_condition, ConditionAuthoring.new()])

    c =
      update_in(c["outcomes"], fn outcomes ->
        Map.new(outcomes, fn {kind, outcome} ->
          {kind, Map.put(outcome, "effects", [opaque, string])}
        end)
      end)

    d = replace_choice(definition(), c)
    work = %{name: "Imported", content_id: "imported", definition: d}
    params = Authoring.form_params(work)

    params =
      Enum.reduce(~w(success partial failure), params, fn kind, params ->
        Map.put(params, "node_0_choice_0_#{kind}_effect_1_value", "quoted \"text\"\nnext\nline")
      end)

    updated = Authoring.apply_form(work, params)
    assert updated == work
    assert Authoring.safe_edit?(d, updated.definition)

    refute Authoring.safe_edit?(
             d,
             put_in(d, ["nodes", Access.at(0), "choices", Access.at(0), "conditions"], [])
           )

    refute Authoring.safe_edit?(
             d,
             put_in(
               d,
               ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "success", "effects"],
               []
             )
           )

    assert ConditionAuthoring.restructure(c["conditions"], "remove", 0) == c["conditions"]
    assert EffectAuthoring.restructure([opaque], "remove", 0) == [opaque]

    for bad <- [<<0>>, <<255>>] do
      altered = Authoring.apply_form(work, %{"node_0_choice_0_condition_1_key" => bad})
      refute Authoring.safe_edit?(d, altered.definition)

      assert Authoring.persistence_errors(Map.take(altered, [:name, :content_id, :definition])) !=
               []
    end

    condition = %{
      "type" => "character_flag",
      "key" => "phrase",
      "flag_type" => "string",
      "value" => string["flag"]["value"]
    }

    assert ConditionAuthoring.apply_form(
             condition,
             %{"c_value" => "quoted \"text\"\nnext\nline"},
             "c"
           ) == condition

    unsupported = Map.put(string, "target", "other_character")
    refute Definition.effect?(unsupported, %{})
    refute EffectAuthoring.editable?(unsupported)
    refute Definition.condition?(Map.put(ConditionAuthoring.new(), "target", "party"), %{})
  end

  test "typed conditions and ordered fixed effects round trip without JSON quoting" do
    choice = Authoring.new_choice() |> Map.put("conditions", [ConditionAuthoring.new()])
    node = Authoring.new_node() |> Map.put("choices", [choice])

    work = %{
      name: "",
      content_id: "",
      definition: %{"start_node" => node["id"], "nodes" => [node]}
    }

    work =
      Authoring.apply_form(work, %{
        "node_0_choice_0_condition_0_key" => "secret",
        "node_0_choice_0_condition_0_flag_type" => "string",
        "node_0_choice_0_condition_0_value" => "plain text",
        "node_0_choice_0_eligibility" => "hidden"
      })

    updated = hd(hd(work.definition["nodes"])["choices"])

    assert updated["conditions"] == [
             %{
               "type" => "character_flag",
               "key" => "secret",
               "flag_type" => "string",
               "value" => "plain text"
             }
           ]

    assert updated["eligibility"] == "hidden"
    assert Authoring.safe_edit?(%{work.definition | "nodes" => [node]}, work.definition)
  end
end
