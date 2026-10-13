defmodule AsyncWorlds.Quests.RolledAuthoringTest do
  use ExUnit.Case, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.Quests.{Authoring, Definition, EffectAuthoring}

  defp replace(definition, choice), do: replace_choice(definition, choice)

  test "conversion retains identity, label, conditions and success content without implicit mode changes" do
    fixed = choice("act", "end") |> Map.put("conditions", [%{"opaque" => true}])
    rolled = Authoring.convert(fixed, "rolled")
    assert rolled["id"] == fixed["id"]
    assert rolled["conditions"] == fixed["conditions"]
    assert rolled["outcomes"]["success"] == fixed["outcomes"]["fixed"]
    assert rolled["outcomes"]["partial"]["text"] == ""
    assert Authoring.safe_edit?(replace(definition(), fixed), replace(definition(), rolled))
    back = Authoring.convert(rolled, "fixed")
    assert back == fixed
    assert Authoring.safe_edit?(replace(definition(), rolled), replace(definition(), back))
    work = %{name: "", content_id: "", definition: replace(definition(), fixed)}

    applied =
      Authoring.apply_form(work, %{
        "node_0_choice_0_mode" => "rolled",
        "node_0_choice_0_dice" => "3"
      })

    assert applied == work
  end

  test "retained unsupported fields are immutable and unsafe conversions do not drop them" do
    opaque = %{"type" => "resource_gain", "resource" => "gold", "amount" => 1, "extra" => [true]}
    c = rolled() |> Map.put("critical_effects", [opaque, EffectAuthoring.new("clear_flag")])
    d = replace(definition(), c)
    assert Authoring.safe_edit?(d, d)
    refute Authoring.convertible?(c)
    assert Authoring.convert(c, "fixed") == c
    work = %{name: "", content_id: "", definition: d}

    edited =
      Authoring.apply_form(work, %{
        "node_0_choice_0_label" => "New label",
        "node_0_choice_0_critical_0_amount" => "999",
        "node_0_choice_0_critical_1_key" => "reward"
      })

    updated = hd(hd(edited.definition["nodes"])["choices"])
    assert hd(updated["critical_effects"]) == opaque
    assert Authoring.safe_edit?(d, edited.definition)
    changed = put_in(d, ["nodes", Access.at(0), "choices", Access.at(0), "critical_effects"], [])
    refute Authoring.safe_edit?(d, changed)
    with_metadata = put_in(c, ["outcomes", "partial", "metadata"], %{"keep" => true})
    refute Authoring.convertible?(with_metadata)
    assert Authoring.convert(with_metadata, "fixed") == with_metadata

    assert EffectAuthoring.form_params(Map.put(EffectAuthoring.new("set_flag"), "extra", opaque)) ==
             %{}

    unknown_flag = put_in(EffectAuthoring.new("set_flag"), ["flag", "type"], "unsupported")
    assert EffectAuthoring.form_params(unknown_flag) == %{}

    assert EffectAuthoring.apply_form(unknown_flag, %{"bonus_value" => "changed"}, "bonus") ==
             unknown_flag
  end

  test "browser-normalized string bonus values preserve original line ending bytes on unrelated edits" do
    effect = %{
      "type" => "set_flag",
      "key" => "note",
      "flag" => %{
        "type" => "string",
        "value" => "first\r\nsecond\rthird\n",
        "player_visible" => false
      }
    }

    unchanged =
      EffectAuthoring.apply_form(
        effect,
        %{"bonus_value" => "first\nsecond\nthird\n", "bonus_visible" => "true"},
        "bonus"
      )

    assert unchanged["flag"]["value"] == effect["flag"]["value"]
    assert unchanged["flag"]["player_visible"]

    changed =
      EffectAuthoring.apply_form(effect, %{"bonus_value" => "intentional\nchange"}, "bonus")

    assert changed["flag"]["value"] == "intentional\nchange"
  end

  test "critical items remain bounded and reject NUL or invalid UTF8 anywhere" do
    old = replace(definition(), rolled() |> Map.put("critical_effects", []))
    path = ["nodes", Access.at(0), "choices", Access.at(0), "critical_effects"]
    effects = List.duplicate(%{"type" => "clear_flag", "key" => "reward"}, 100)
    assert Authoring.safe_edit?(old, put_in(old, path, effects))
    refute Authoring.safe_edit?(old, put_in(old, path, effects ++ effects))
    assert EffectAuthoring.restructure(effects, "set_flag", nil) == effects
    assert length(EffectAuthoring.restructure(Enum.take(effects, 99), "set_flag", nil)) == 100
    opaque = %{"type" => "resource", "amount" => 1}

    for index <- [nil, -1, 101, [], %{}, "bad"],
        do: assert(EffectAuthoring.restructure([opaque], "remove", index) == [opaque])

    assert EffectAuthoring.restructure([opaque], "remove", 0) == [opaque]

    for invalid <- ["bad" <> <<0>>, <<255>>] do
      effect = %{
        "type" => "set_flag",
        "key" => "reward",
        "flag" => %{"type" => "string", "value" => invalid, "player_visible" => false}
      }

      new = put_in(old, path, [effect])
      refute Authoring.safe_edit?(old, new)

      assert [{"nodes[0].choices[0].critical_effects[0].flag.value", _}] =
               Authoring.persistence_errors(%{definition: new})
    end
  end

  test "shared release diagnostics explain pools, missing branches, fixed incompatibilities and typed effects" do
    for pool <- 1..3 do
      definition = replace(definition(), Map.put(rolled(), "dice", pool))
      assert Definition.valid?(definition, %{})
      assert Definition.errors(definition, %{}) == []
    end

    for invalid <- [0, 4, 1.0, "2", nil] do
      errors = Definition.errors(replace(definition(), Map.put(rolled(), "dice", invalid)), %{})
      assert {"nodes[0].choices[0].dice", "Pool must be an integer from 1 to 3 d6"} in errors
    end

    fixed = choice("act", "end") |> Map.put("dice", 1) |> Map.put("critical_effects", [])
    paths = Definition.errors(replace(definition(), fixed), %{}) |> Enum.map(&elem(&1, 0))
    assert "nodes[0].choices[0].dice" in paths
    assert "nodes[0].choices[0].critical_effects" in paths
    missing = rolled() |> update_in(["outcomes"], &Map.delete(&1, "partial"))

    assert Enum.any?(Definition.errors(replace(definition(), missing), %{}), fn {path, message} ->
             String.ends_with?(path, ".outcomes") and message =~ "success, partial, failure"
           end)

    effects = [
      EffectAuthoring.new("clock_delta"),
      EffectAuthoring.new("set_flag"),
      %{"type" => "resources"}
    ]

    paths =
      Definition.errors(
        replace(definition(), Map.put(rolled(), "critical_effects", effects)),
        %{}
      )
      |> Enum.map(&elem(&1, 0))

    assert "nodes[0].choices[0].critical_effects[0].clock_id" in paths
    assert "nodes[0].choices[0].critical_effects[1].key" in paths
    assert "nodes[0].choices[0].critical_effects[2].type" in paths
  end
end
