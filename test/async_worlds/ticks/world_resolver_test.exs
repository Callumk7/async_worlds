defmodule AsyncWorlds.Ticks.WorldResolverTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Ticks.{Snapshot, WorldResolver}

  defp clock(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "campaign_id" => 1,
        "name" => "Clock #{id}",
        "segments" => 4,
        "filled" => 0,
        "visibility" => "public",
        "background_rate" => 0,
        "paused" => false,
        "completed" => false,
        "racing_group" => nil,
        "triggers" => []
      },
      attrs
    )
  end

  defp snapshot(clocks) do
    %Snapshot{
      schema_version: 1,
      revision: "frozen-input",
      data: %{
        "campaign" => %{"id" => 1},
        "tick_number" => 3,
        "clocks" => clocks,
        "ordering" => %{
          "clocks" => clocks |> Enum.map(& &1["id"]) |> Enum.sort(),
          "race_tie_break" => "ascending_clock_id",
          "phases" =>
            ~w(quest_choices resource_assignments background_rates clock_triggers quest_conditions)
        }
      }
    }
  end

  defp resolve(clocks) do
    assert {:ok, draft} = WorldResolver.resolve(snapshot(clocks))
    draft
  end

  defp result(draft, id), do: Enum.find(draft["clocks"], &(&1["id"] == id))

  test "empty world and repeated resolution are deterministic JSON-compatible drafts" do
    input = snapshot([])
    assert {:ok, draft} = WorldResolver.resolve(input)
    assert draft["clocks"] == []
    assert draft["log"] == []
    assert {:ok, ^draft} = WorldResolver.resolve(input)
    assert Jason.decode!(Jason.encode!(draft)) == draft
  end

  test "rates clamp bounds, record actual deltas, and preserve hidden/known metadata" do
    draft =
      resolve([
        clock(2, %{"filled" => 1, "background_rate" => -8, "visibility" => "hidden"}),
        clock(1, %{"filled" => 3, "background_rate" => 8, "visibility" => "known"})
      ])

    assert result(draft, 1)["filled"] == 4
    assert result(draft, 1)["completed"]
    assert result(draft, 1)["visibility"] == "known"
    assert result(draft, 2)["filled"] == 0
    assert result(draft, 2)["visibility"] == "hidden"
    assert [first, second | _] = draft["effects"]
    assert {first["clock_id"], first["requested_delta"], first["applied_delta"]} == {1, 8, 1}
    assert {second["clock_id"], second["requested_delta"], second["applied_delta"]} == {2, -8, -1}
    assert first["source"] == "background:tick:3"
  end

  test "all supported sizes preserve bounds and latch completion across signed rates" do
    for segments <- [4, 6, 8], filled <- 0..segments, rate <- [-10, -1, 0, 1, 10] do
      draft =
        resolve([
          clock(1, %{"segments" => segments, "filled" => filled, "background_rate" => rate})
        ])

      after_clock = result(draft, 1)
      expected_fill = max(0, min(segments, filled + rate))
      assert after_clock["filled"] == expected_fill
      assert after_clock["completed"] == (filled == segments or expected_fill == segments)
    end
  end

  test "paused and completed clocks skip rates; completed clocks never fire" do
    draft =
      resolve([
        clock(1, %{"paused" => true, "background_rate" => 4}),
        clock(2, %{
          "completed" => true,
          "filled" => 4,
          "background_rate" => -1,
          "triggers" => [%{"type" => "world_news", "text" => "Never"}]
        })
      ])

    assert result(draft, 1)["filled"] == 0
    assert result(draft, 2)["filled"] == 4
    assert draft["log"] == []
  end

  test "initial full eligibility survives negative rates and pause" do
    draft =
      resolve([
        clock(1, %{
          "filled" => 4,
          "background_rate" => -2,
          "triggers" => [%{"type" => "world_news", "text" => "Filled earlier"}]
        }),
        clock(2, %{
          "filled" => 4,
          "paused" => true,
          "background_rate" => -4,
          "triggers" => [%{"type" => "notify_dm", "text" => "Paused but full"}]
        })
      ])

    assert result(draft, 1)["filled"] == 2
    assert result(draft, 1)["completed"]
    assert result(draft, 2)["filled"] == 4
    assert result(draft, 2)["completed"]
    assert draft["world_news"] == ["Filled earlier"]
    assert draft["dm_notifications"] == ["Paused but full"]
  end

  test "race first fill wins even if both fill in the background phase" do
    draft =
      resolve([
        clock(2, %{
          "racing_group" => "race",
          "background_rate" => 4,
          "triggers" => [%{"type" => "world_news", "text" => "Loser"}]
        }),
        clock(1, %{
          "racing_group" => "race",
          "background_rate" => 4,
          "triggers" => [%{"type" => "world_news", "text" => "Winner"}]
        })
      ])

    assert draft["race_winners"] == [%{"racing_group" => "race", "clock_id" => 1}]
    assert result(draft, 1)["completed"]
    assert result(draft, 2)["completed"]
    assert result(draft, 2)["filled"] == 4
    assert draft["world_news"] == ["Winner"]
  end

  test "a racing loser completes without filling or firing its start trigger" do
    draft =
      resolve([
        clock(1, %{"racing_group" => "race", "filled" => 3, "background_rate" => 1}),
        clock(2, %{
          "racing_group" => "race",
          "filled" => 1,
          "triggers" => [%{"type" => "start_clock", "clock_id" => 3}]
        }),
        clock(3, %{"paused" => true, "background_rate" => 4})
      ])

    assert result(draft, 2)["completed"]
    assert result(draft, 2)["filled"] == 1
    assert result(draft, 3)["paused"]
    assert draft["trigger_results"] == []
  end

  test "initial full race beats an earlier-ID rate fill and remains latched after a negative rate" do
    draft =
      resolve([
        clock(1, %{
          "racing_group" => "race",
          "background_rate" => 4,
          "triggers" => [%{"type" => "world_news", "text" => "Loser"}]
        }),
        clock(2, %{
          "racing_group" => "race",
          "filled" => 4,
          "background_rate" => -4,
          "triggers" => [%{"type" => "world_news", "text" => "Initial winner"}]
        })
      ])

    assert draft["race_winners"] == [%{"racing_group" => "race", "clock_id" => 2}]
    assert result(draft, 2)["filled"] == 0
    assert result(draft, 1)["completed"]
    assert draft["world_news"] == ["Initial winner"]
  end

  test "initial full racing tie uses ascending ID and reset inputs permit another race" do
    clocks = for id <- [2, 1], do: clock(id, %{"racing_group" => "race", "filled" => 4})
    draft = resolve(clocks)
    assert draft["race_winners"] == [%{"racing_group" => "race", "clock_id" => 1}]
    assert resolve(draft["clocks"])["race_winners"] == []
    reset = Enum.map(draft["clocks"], &Map.merge(&1, %{"filled" => 0, "completed" => false}))
    assert resolve(reset)["effects"] == []
    next = Enum.map(reset, &Map.put(&1, "background_rate", 4))
    assert resolve(next)["race_winners"] == [%{"racing_group" => "race", "clock_id" => 1}]
  end

  test "start unpauses without applying missed rates; repeated starts become no-ops" do
    draft =
      resolve([
        clock(1, %{
          "filled" => 4,
          "triggers" => [
            %{"type" => "start_clock", "clock_id" => 2},
            %{"type" => "start_clock", "clock_id" => 2},
            %{"type" => "world_news", "text" => "Third"}
          ]
        }),
        clock(2, %{"paused" => true, "filled" => 1, "background_rate" => 4})
      ])

    refute result(draft, 2)["paused"]
    assert result(draft, 2)["filled"] == 1
    refute result(draft, 2)["completed"]
    assert [first, second, news] = draft["trigger_results"]
    assert first["changed"]
    refute second["changed"]
    assert first["target_clock_id"] == 2
    assert first["source"] == "trigger:tick:3:clock:1:0"
    assert news["trigger_index"] == 2
  end

  test "cyclic full start chains terminate; completed targets are never resurrected" do
    input =
      snapshot([
        clock(1, %{
          "filled" => 4,
          "paused" => true,
          "triggers" => [%{"type" => "start_clock", "clock_id" => 2}]
        }),
        clock(2, %{
          "filled" => 4,
          "paused" => true,
          "triggers" => [
            %{"type" => "start_clock", "clock_id" => 1},
            %{"type" => "start_clock", "clock_id" => 3}
          ]
        }),
        clock(3, %{"completed" => true, "paused" => true, "filled" => 4})
      ])

    assert {:ok, draft} = WorldResolver.resolve(input)
    assert length(draft["trigger_results"]) == 3
    assert Enum.all?(draft["clocks"], & &1["completed"])
    assert result(draft, 1)["paused"]
    assert result(draft, 3)["paused"]
    assert Enum.map(draft["log"], & &1["sequence"]) == Enum.to_list(1..length(draft["log"]))
    assert {:ok, ^draft} = WorldResolver.resolve(input)
  end

  test "clock input enumeration does not affect output, and triggers retain stored order" do
    clocks = [
      clock(2, %{"background_rate" => 4}),
      clock(1, %{
        "background_rate" => 4,
        "triggers" => [
          %{"type" => "world_news", "text" => "One"},
          %{"type" => "notify_dm", "text" => "Two"},
          %{"type" => "world_news", "text" => "Three"}
        ]
      })
    ]

    assert resolve(clocks) == resolve(Enum.reverse(clocks))
    assert resolve(clocks)["world_news"] == ["One", "Three"]
  end

  test "invalid schema, ordering, ownership, bounds, triggers and races fail closed" do
    good = snapshot([clock(1)])

    bad_clocks = [
      [clock(1), clock(1)],
      [clock(1, %{"campaign_id" => 2})],
      [clock(1, %{"segments" => 5})],
      [clock(1, %{"filled" => -1})],
      [clock(1, %{"filled" => 5})],
      [clock(1, %{"paused" => "true"})],
      [clock(1, %{"racing_group" => "orphan"})],
      Enum.map(1..3, &clock(&1, %{"racing_group" => "race"})),
      [
        clock(1, %{"racing_group" => "race"}),
        clock(2, %{"racing_group" => "race", "completed" => true})
      ],
      [clock(1, %{"triggers" => [%{"type" => "start_clock", "clock_id" => 1}]})],
      [clock(1, %{"triggers" => [%{"type" => "start_clock", "clock_id" => 999}]})],
      [clock(1, %{"triggers" => [%{"type" => "world_news", "text" => " "}]})],
      [clock(1, %{"triggers" => [%{"type" => "set_flag"}]})],
      [nil]
    ]

    for clocks <- bad_clocks do
      ids = for clock <- clocks, is_map(clock), do: clock["id"]

      data =
        good.data |> Map.put("clocks", clocks) |> put_in(["ordering", "clocks"], Enum.sort(ids))

      input = %{good | data: data}
      assert {:error, :invalid_snapshot} = WorldResolver.resolve(input)
    end

    assert {:error, :invalid_snapshot} = WorldResolver.resolve(%{good | revision: ""})
    assert {:error, :invalid_snapshot} = WorldResolver.resolve(%{good | schema_version: 2})
    assert {:error, :invalid_snapshot} = WorldResolver.resolve(%{good | data: %{}})
    assert {:error, :invalid_snapshot} = WorldResolver.resolve(nil)

    wrong_phases =
      put_in(good.data, ["ordering", "phases"], ["clock_triggers", "background_rates"])

    assert {:error, :invalid_snapshot} = WorldResolver.resolve(%{good | data: wrong_phases})
    wrong_order = put_in(good.data, ["ordering", "clocks"], [2])
    assert {:error, :invalid_snapshot} = WorldResolver.resolve(%{good | data: wrong_order})
  end
end
