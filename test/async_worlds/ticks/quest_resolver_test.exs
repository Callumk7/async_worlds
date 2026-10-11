defmodule AsyncWorlds.Ticks.QuestResolverTest do
  use ExUnit.Case, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.Ticks.{QuestDice, Snapshot, WorldResolver}

  defp clock(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "campaign_id" => 1,
        "name" => "Clock",
        "segments" => 4,
        "filled" => 0,
        "background_rate" => 0,
        "completed" => false,
        "paused" => false,
        "visibility" => "hidden",
        "racing_group" => nil,
        "triggers" => []
      },
      attrs
    )
  end

  defp snapshot(definition \\ definition(), clocks \\ [clock(1)], submitted \\ [1]) do
    %Snapshot{
      schema_version: 2,
      revision: "frozen",
      data: %{
        "campaign" => %{"id" => 1},
        "tick_number" => 1,
        "clocks" => clocks,
        "ordering" => %{
          "clocks" => Enum.map(clocks, & &1["id"]),
          "race_tie_break" => "ascending_clock_id",
          "phases" =>
            ~w(quest_choices resource_assignments background_rates clock_triggers quest_conditions)
        },
        "quest_inputs" => %{
          "characters" =>
            for(
              id <- 1..3,
              do: %{"id" => id, "name" => "Player", "discord_user_id" => "#{id}", "flags" => %{}}
            ),
          "quests" => [%{"id" => 1, "content_id" => "quest", "name" => "Quest"}],
          "revisions" => [
            %{"id" => 1, "quest_id" => 1, "number" => 1, "definition" => definition}
          ],
          "progressions" =>
            for(
              id <- 1..3,
              do: %{
                "id" => id,
                "character_id" => id,
                "revision_id" => 1,
                "node_id" => "hub",
                "position_version" => 1,
                "status" => "active"
              }
            ),
          "submissions" =>
            for(
              id <- submitted,
              do: %{
                "character_id" => id,
                "progression_id" => id,
                "revision_id" => 1,
                "node_id" => "hub",
                "position_version" => 1,
                "choice_id" => hd(hd(definition["nodes"])["choices"])["id"]
              }
            ),
          "invalidations" => []
        }
      }
    }
  end

  defp dice(snapshot, values),
    do:
      Enum.zip(QuestDice.specs(snapshot), values)
      |> Enum.map(fn {s, v} -> Map.put(s, "value", v) end)

  defp resolve(snapshot, values \\ []) do
    assert {:ok, draft} = WorldResolver.resolve(snapshot, %{}, dice(snapshot, values))
    assert Jason.decode!(Jason.encode!(draft)) == draft
    draft
  end

  test "fixed cycles, flag clear/set, endings and missing/invalid submissions" do
    s = snapshot()
    draft = resolve(s)
    assert hd(draft["characters"])["flags"] == %{"secret" => flag()}
    assert Enum.map(draft["progressions"], & &1["node_id"]) == ["hub", "hub", "hub"]
    assert Enum.map(draft["private_results"], & &1["character_id"]) == [1]
    assert draft["rolls"] == []
    s = put_in(s.data["quest_inputs"]["submissions"], [])

    s =
      put_in(s.data["quest_inputs"]["invalidations"], [
        %{"character_id" => 1, "reason" => "stale_or_ineligible"}
      ])

    assert resolve(s)["private_results"] == []

    end_definition =
      replace_choice(
        definition(),
        choice("finish", "end", [%{"type" => "clear_flag", "key" => "secret"}])
      )

    ending = resolve(snapshot(end_definition))
    assert hd(ending["progressions"])["status"] == "completed"

    assert hd(ending["next_nodes"])["projection"] == %{
             "text" => "Ending",
             "completed" => true,
             "choices" => []
           }

    assert hd(s.data["quest_inputs"]["characters"])["flags"] == %{}
  end

  test "every 1-3 d6 combination keeps highest and critical appends only configured bonus" do
    for count <- 1..3 do
      choice = Map.put(rolled(), "dice", count)
      s = snapshot(replace_choice(definition(), choice))

      pools =
        Enum.reduce(1..count, [[]], fn _, pools ->
          for pool <- pools, die <- 1..6, do: pool ++ [die]
        end)

      for values <- pools do
        draft = resolve(s, values)
        [result] = draft["private_results"]

        expected =
          cond do
            Enum.max(values) == 6 -> "success"
            Enum.max(values) >= 4 -> "partial"
            true -> "failure"
          end

        assert result["outcome"] == expected
        assert result["critical"] == Enum.count(values, &(&1 == 6)) >= 2
        assert Map.has_key?(hd(draft["characters"])["flags"], "bonus") == result["critical"]

        assert hd(draft["progressions"])["node_id"] ==
                 if(expected == "success", do: "end", else: "hub")

        assert {:ok, ^draft} = WorldResolver.resolve(s, %{}, dice(s, values))
      end
    end
  end

  test "ordered set/clear effects, clamping and completed-clock no-ops remain auditable" do
    effects = [
      %{"type" => "set_flag", "key" => "temporary", "flag" => flag()},
      %{"type" => "clear_flag", "key" => "temporary"},
      %{"type" => "clock_delta", "clock_id" => 1, "delta" => -9},
      %{"type" => "clock_delta", "clock_id" => 2, "delta" => -9}
    ]

    defn = replace_choice(definition(), choice("act", "hub", effects))

    draft =
      resolve(
        snapshot(defn, [
          clock(1, %{"filled" => 1}),
          clock(2, %{"filled" => 4, "completed" => true})
        ])
      )

    assert hd(draft["characters"])["flags"] == %{}
    assert Enum.map(draft["clocks"], & &1["filled"]) == [0, 4]
    authored = Enum.filter(draft["log"], &(&1["kind"] == "quest_effect"))
    assert Enum.map(authored, & &1["effect"]) == effects
    assert length(draft["effects"]) == 1
    assert hd(draft["effects"])["applied_delta"] == -1
    choice = Map.put(rolled(), "critical_effects", [])
    critical = resolve(snapshot(replace_choice(definition(), choice)), [6, 6, 6])
    assert hd(critical["private_results"])["critical"]
    assert hd(critical["characters"])["flags"] == %{}
  end

  test "missing, extra, malformed or foreign dice fail closed; fixed consumes no dice" do
    s = snapshot(replace_choice(definition(), rolled()))
    rolls = dice(s, [6, 6, 1])

    for invalid <- [
          [],
          tl(rolls),
          rolls ++ rolls,
          [Map.put(hd(rolls), "value", 7) | tl(rolls)],
          [Map.put(hd(rolls), "input", %{}) | tl(rolls)],
          Enum.reverse(rolls)
        ] do
      assert {:error, :invalid_rolls} = WorldResolver.resolve(s, %{}, invalid)
    end

    assert {:error, :invalid_rolls} = WorldResolver.resolve(snapshot(), %{}, rolls)
    assert QuestDice.specs(%{s | revision: "new"}) != QuestDice.specs(s)
  end

  test "character order, individual effect order and first-fill latch beat background ID order" do
    effects = [
      %{"type" => "clock_delta", "clock_id" => 2, "delta" => 4},
      %{"type" => "clock_delta", "clock_id" => 2, "delta" => -4}
    ]

    defn = replace_choice(definition(), choice("act", "hub", effects))

    clocks = [
      clock(1, %{
        "racing_group" => "race",
        "background_rate" => 4,
        "triggers" => [%{"type" => "world_news", "text" => "loser"}]
      }),
      clock(2, %{
        "racing_group" => "race",
        "triggers" => [%{"type" => "world_news", "text" => "winner"}]
      })
    ]

    draft = resolve(snapshot(defn, clocks, [1, 2]))
    assert draft["race_winners"] == [%{"racing_group" => "race", "clock_id" => 2}]
    assert draft["world_news"] == ["winner"]
    assert Enum.map(draft["private_results"], & &1["character_id"]) == [1, 2]
    assert Enum.map(Enum.take(draft["effects"], 4), & &1["applied_delta"]) == [4, -4, 4, -4]
    assert Enum.all?(Enum.take(draft["effects"], 4), &(&1["phase"] == "quest_choices"))
    assert Enum.map(draft["log"], & &1["sequence"]) == Enum.to_list(1..length(draft["log"]))
    assert Enum.all?(draft["clocks"], & &1["completed"])
    assert List.last(draft["clocks"])["filled"] == 0
  end

  test "frozen eligibility is not rechecked mid-turn; next-node conditions use final clocks and trigger flags" do
    condition = %{"type" => "clock_threshold", "clock_id" => 1, "operator" => "lte", "value" => 0}

    act =
      choice("act", "hub", [%{"type" => "clock_delta", "clock_id" => 1, "delta" => 4}])
      |> Map.put("conditions", [condition])

    gated =
      choice("gated", "hub")
      |> Map.put("conditions", [
        %{
          "type" => "character_flag",
          "key" => "unlocked",
          "flag_type" => "boolean",
          "value" => true
        }
      ])

    hidden = Map.put(gated, "id", "hidden") |> Map.put("eligibility", "hidden")
    defn = definition() |> replace_choice(act)
    [hub, ending] = defn["nodes"]
    defn = Map.put(defn, "nodes", [Map.put(hub, "choices", [act, gated, hidden]), ending])

    clocks = [
      clock(1, %{
        "background_rate" => -2,
        "triggers" => [
          %{"type" => "set_flag", "character_id" => 1, "key" => "unlocked", "flag" => flag()},
          %{"type" => "unlock_quest", "character_id" => 3, "quest_id" => 1}
        ]
      })
    ]

    draft = resolve(snapshot(defn, clocks, [1, 2]))
    assert length(draft["private_results"]) == 2
    assert hd(draft["clocks"])["filled"] == 2
    assert draft["unlocked_quests"] == [%{"character_id" => 3, "quest_ids" => [1]}]
    [first, second, _] = draft["next_nodes"]
    assert Enum.map(first["projection"]["choices"], & &1["enabled"]) == [false, true, true]
    assert Enum.map(second["projection"]["choices"], & &1["enabled"]) == [false, false]
    assert Enum.all?(draft["trigger_results"], &(&1["phase"] == "clock_triggers"))
  end

  test "initial-full race latches before quests; cyclic start chains and dependent triggers fire once" do
    effects = [%{"type" => "clock_delta", "clock_id" => 1, "delta" => 4}]
    defn = replace_choice(definition(), choice("act", "hub", effects))

    clocks = [
      clock(1, %{"racing_group" => "race"}),
      clock(2, %{
        "racing_group" => "race",
        "filled" => 4,
        "background_rate" => -4,
        "triggers" => [%{"type" => "start_clock", "clock_id" => 3}]
      }),
      clock(3, %{
        "filled" => 4,
        "paused" => true,
        "triggers" => [
          %{"type" => "start_clock", "clock_id" => 2},
          %{"type" => "set_flag", "character_id" => 3, "key" => "chain", "flag" => flag()},
          %{"type" => "unlock_quest", "character_id" => 3, "quest_id" => 1},
          %{"type" => "unlock_quest", "character_id" => 3, "quest_id" => 1}
        ]
      })
    ]

    draft = resolve(snapshot(defn, clocks))
    assert draft["race_winners"] == [%{"racing_group" => "race", "clock_id" => 2}]
    assert length(draft["trigger_results"]) == 5
    assert Enum.map(draft["trigger_results"], & &1["clock_id"]) == [2, 3, 3, 3, 3]
    refute List.last(draft["trigger_results"])["changed"]
    assert List.last(draft["characters"])["flags"] == %{"chain" => flag()}
  end
end
