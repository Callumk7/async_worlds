defmodule AsyncWorlds.QuestsRulesTest do
  use ExUnit.Case, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.Quests.{Definition, Rules}
  alias AsyncWorlds.Clocks.Clock

  defp state, do: %{node_id: "hub", status: :active, flags: %{}, clocks: %{}}

  test "two frozen characters independently traverse cycles, flags and intentional endings" do
    a = state()
    b = state()
    assert Definition.valid?(definition(), %{})

    assert {:ok, a, %{outcome: "fixed", critical: false}} =
             Rules.transition(definition(), a, "loop")

    assert a.node_id == "hub"
    assert a.flags == %{"secret" => flag()}
    assert b.flags == %{}
    assert {:ok, b, _} = Rules.transition(definition(), b, "finish")
    assert b.node_id == "end" and b.status == :completed
    assert a.status == :active
    assert {:ok, a, _} = Rules.transition(definition(), a, "finish")
    assert a.flags == %{} and a.status == :completed
    assert Rules.project(definition(), a) == %{text: "Ending", completed: true, choices: []}
    assert {:error, :invalid_transition} = Rules.transition(definition(), a, "loop")
  end

  test "invalid frozen clock/state inputs return errors instead of crashing" do
    d =
      replace_choice(
        definition(),
        choice("act", "hub", [%{"type" => "clock_delta", "clock_id" => 1, "delta" => 1}])
      )

    for clock <- [
          nil,
          %{},
          %{segments: 4, filled: "bad", completed: false},
          %{segments: 4, filled: 0, completed: nil}
        ] do
      s = %{state() | clocks: %{1 => clock}}
      refute Definition.valid?(d, s.clocks)
      assert {:error, :invalid_transition} = Rules.transition(d, s, "act")
    end

    for s <- [%{flags: %{}, clocks: %{}}, %{state() | status: :unknown}] do
      assert {:error, :invalid_transition} = Rules.transition(definition(), s, "loop")
    end
  end

  test "recorded dice use highest, with two sixes success then bonus effects" do
    d = replace_choice(definition(), rolled())

    for {dice, expected} <- [
          {[1, 2, 3], "failure"},
          {[1, 4, 2], "partial"},
          {[5, 2, 1], "partial"},
          {[6, 1, 2], "success"}
        ] do
      assert {:ok, next, result} = Rules.transition(d, state(), "roll", dice)
      assert result.outcome == expected
      refute result.critical
      assert next.flags == %{}
    end

    assert {:ok, next, %{critical: true, outcome: "success"}} =
             Rules.transition(d, state(), "roll", [6, 1, 6])

    assert next.flags == %{"bonus" => flag(true, true)}

    for dice <- [[], [6], [6, 6], [6, 6, 7], [0, 1, 2], [1.0, 2, 3], :bad] do
      assert {:error, :invalid_transition} = Rules.transition(d, state(), "roll", dice)
    end

    assert {:error, :invalid_transition} = Rules.transition(definition(), state(), "loop", [6])
  end

  test "typed clock/flag AND conditions and ordered clamped clock and set/clear effects" do
    clock = %Clock{id: 1, segments: 4, filled: 3, completed: false}
    clocks = %{1 => clock}

    conditions = [
      %{"type" => "clock_threshold", "clock_id" => 1, "operator" => "gte", "value" => 3},
      %{"type" => "character_flag", "key" => "secret", "flag_type" => "boolean", "value" => true}
    ]

    effects = [
      %{"type" => "clock_delta", "clock_id" => 1, "delta" => 9},
      %{"type" => "clock_delta", "clock_id" => 1, "delta" => -2},
      %{"type" => "set_flag", "key" => "other", "flag" => flag()},
      %{"type" => "clear_flag", "key" => "other"}
    ]

    c = Map.put(choice("act", "hub", effects), "conditions", conditions)
    d = replace_choice(definition(), c)
    s = %{state() | clocks: clocks, flags: %{"secret" => flag()}}
    assert Definition.valid?(d, clocks)
    assert {:ok, next, _} = Rules.transition(d, s, "act")
    assert next.clocks[1].filled == 2
    refute Map.has_key?(next.flags, "other")
    assert {:error, :invalid_transition} = Rules.transition(d, %{s | flags: %{}}, "act")
    refute Rules.eligible?(c, %{"secret" => %{"type" => "integer", "value" => 1}}, clocks)

    lte =
      put_in(c["conditions"], [
        %{"type" => "clock_threshold", "clock_id" => 1, "operator" => "lte", "value" => 3}
      ])

    assert Rules.eligible?(lte, %{}, clocks)
  end

  test "privacy omits hidden ineligible choices and never explains conditions, hidden flags or fills" do
    condition = %{
      "type" => "character_flag",
      "key" => "secret",
      "flag_type" => "boolean",
      "value" => true
    }

    [hub, ending] = definition()["nodes"]

    hidden =
      choice("hidden", "hub")
      |> Map.merge(%{"conditions" => [condition], "eligibility" => "hidden"})

    disabled = choice("disabled", "hub") |> Map.put("conditions", [condition])

    d =
      put_in(definition()["nodes"], [
        Map.put(hub, "choices", [hidden, disabled, choice("always", "hub")]),
        ending
      ])

    assert Rules.project(d, state()) == %{
             text: "Hub",
             completed: false,
             choices: [
               %{
                 id: "disabled",
                 label: "disabled",
                 enabled: false,
                 hint: "Not available right now."
               },
               %{id: "always", label: "always", enabled: true}
             ]
           }

    assert %{choices: [%{id: "hidden"}, %{id: "disabled"}, %{id: "always"}]} =
             Rules.project(d, %{state() | flags: %{"secret" => flag()}})
  end

  test "all ENG-13 flag types retain native equality and visibility on effects" do
    for {type, value} <- [{"boolean", false}, {"integer", -2}, {"string", "Guild"}],
        visible <- [true, false] do
      fact = %{"type" => type, "value" => value, "player_visible" => visible}
      effect = %{"type" => "set_flag", "key" => "fact", "flag" => fact}
      d = replace_choice(definition(), choice("set", "hub", [effect]))
      assert {:ok, next, _} = Rules.transition(d, state(), "set")
      assert next.flags == %{"fact" => fact}

      condition = %{
        "type" => "character_flag",
        "key" => "fact",
        "flag_type" => type,
        "value" => value
      }

      c = Map.put(choice("test", "hub"), "conditions", [condition])
      assert Rules.eligible?(c, next.flags, %{})
      refute Rules.eligible?(c, %{}, %{})
      wrong = Map.put(fact, "value", if(type == "string", do: "Other", else: "wrong"))
      refute Rules.eligible?(c, %{"fact" => wrong}, %{})

      assert Rules.project(d, next) == %{
               text: "Hub",
               completed: false,
               choices: [%{id: "set", label: "set", enabled: true}]
             }
    end
  end

  test "critical effects run after success effects and every supported dice pool works" do
    success_effect = %{"type" => "set_flag", "key" => "secret", "flag" => flag()}
    bonus = %{"type" => "clear_flag", "key" => "secret"}

    c =
      rolled()
      |> put_in(["outcomes", "success", "effects"], [success_effect])
      |> Map.put("critical_effects", [bonus])

    for count <- 1..3 do
      d = replace_choice(definition(), Map.put(c, "dice", count))
      dice = List.duplicate(6, count)
      assert {:ok, next, result} = Rules.transition(d, state(), "roll", dice)
      assert result.critical == count >= 2
      assert next.flags == if(count == 1, do: %{"secret" => flag()}, else: %{})
      assert result.effects == if(count == 1, do: [success_effect], else: [success_effect, bonus])
    end
  end

  test "invalid input and flag-capacity effects do not yield a partial transition" do
    for bad <- [nil, %{}, %{flags: %{}, clocks: %{}}, %{state() | node_id: "missing"}] do
      assert {:error, :invalid_transition} = Rules.transition(definition(), bad, "loop")
    end

    flags = Map.new(1..100, &{"flag_#{&1}", flag()})
    s = %{state() | flags: flags}
    assert {:error, :invalid_flags} = Rules.transition(definition(), s, "loop")
    assert s.flags == flags
  end

  test "malformed definitions, typed conditions/effects, foreign nodes, endings and configs reject" do
    fixed = choice("a", "hub")

    bad_choices = [
      Map.put(fixed, "mode", "resource"),
      Map.put(fixed, "dice", 1),
      Map.put(fixed, "critical_effects", []),
      Map.put(fixed, "eligibility", "show"),
      Map.put(fixed, "conditions", [%{"type" => "resource"}]),
      Map.put(fixed, "conditions", [
        %{"type" => "character_flag", "key" => "Bad", "flag_type" => "boolean", "value" => true}
      ]),
      Map.put(fixed, "conditions", [
        %{"type" => "character_flag", "key" => "secret", "flag_type" => "boolean", "value" => 1}
      ]),
      Map.put(fixed, "conditions", [
        %{"type" => "clock_threshold", "clock_id" => 99, "operator" => "gte", "value" => 1}
      ]),
      put_in(fixed["outcomes"]["fixed"]["next_node"], "foreign"),
      put_in(fixed["outcomes"]["fixed"]["effects"], [
        %{
          "type" => "set_flag",
          "key" => "secret",
          "flag" => %{"type" => "boolean", "value" => true}
        }
      ]),
      put_in(fixed["outcomes"]["fixed"]["effects"], [
        %{"type" => "clock_delta", "clock_id" => 1, "delta" => "1"}
      ]),
      put_in(fixed["outcomes"]["fixed"]["effects"], [
        %{"type" => "clear_flag", "key" => "x", "character_id" => 1}
      ]),
      Map.put(fixed, "outcomes", %{}),
      Map.put(fixed, "outcomes", %{"success" => outcome("hub")}),
      Map.put(rolled(), "dice", 0),
      Map.put(rolled(), "dice", 4),
      Map.put(rolled(), "dice", 1.0),
      Map.delete(rolled(), "critical_effects"),
      Map.put(rolled(), "critical_effects", [%{"type" => "resource"}]),
      Map.put(rolled(), "outcomes", %{"success" => outcome("hub")})
    ]

    for bad <- bad_choices, do: refute(Definition.valid?(replace_choice(definition(), bad), %{}))
    [hub, ending] = definition()["nodes"]

    for bad <- [
          nil,
          [],
          %{},
          Map.put(definition(), "start_node", "missing"),
          put_in(definition()["nodes"], [hub, hub]),
          put_in(definition()["nodes"], [Map.put(hub, "ending", true), ending]),
          put_in(definition()["nodes"], [hub, Map.put(ending, "ending", false)]),
          put_in(definition()["nodes"], [Map.put(hub, "choices", [fixed, fixed]), ending])
        ] do
      refute Definition.valid?(bad, %{})
    end

    clock = %Clock{id: 1, segments: 4}

    for {op, value} <- [{"gt", 1}, {"gte", -1}, {"gte", 5}, {"lte", "3"}] do
      refute Definition.condition?(
               %{
                 "type" => "clock_threshold",
                 "clock_id" => 1,
                 "operator" => op,
                 "value" => value
               },
               %{1 => clock}
             )
    end
  end
end
