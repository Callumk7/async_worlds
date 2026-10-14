defmodule AsyncWorlds.Ticks.ReviewProjectionTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Ticks.{ReviewProjection, Snapshot}

  test "frozen roster includes submitted, missing and ending players without attributing other choices" do
    characters = for id <- 1..3, do: %{"id" => id, "name" => "Player #{id}", "flags" => %{}}

    progressions =
      for id <- 1..3,
          do: %{
            "character_id" => id,
            "node_id" => "hub",
            "status" => if(id == 3, do: "completed", else: "active")
          }

    result = %{
      "character_id" => 1,
      "source" => "quest:character:1:choice:roll",
      "after" => %{"status" => "completed"}
    }

    own = %{
      "kind" => "clock_change",
      "clock_id" => 10,
      "phase" => "quest_choices",
      "source" => result["source"] <> ":effect:0"
    }

    other = Map.put(own, "source", "quest:character:2:choice:roll:effect:0")

    trigger = %{
      "kind" => "trigger_result",
      "clock_id" => 10,
      "target_clock_id" => 20,
      "phase" => "clock_triggers",
      "source" => "trigger:10"
    }

    chained = %{
      "kind" => "trigger_result",
      "clock_id" => 20,
      "target_clock_id" => 10,
      "phase" => "clock_triggers",
      "source" => "trigger:20"
    }

    snapshot = %Snapshot{
      data: %{"quest_inputs" => %{"characters" => characters, "progressions" => progressions}}
    }

    payload = %{
      "characters" => characters,
      "progressions" => progressions,
      "private_results" => [result],
      "next_nodes" => [],
      "effects" => [own, other],
      "trigger_results" => [trigger, chained],
      "log" => [own, other, trigger, chained]
    }

    [submitted, missing, ending] = ReviewProjection.players(payload, snapshot)
    assert submitted.state == "Submitted · ending"
    assert submitted.consequences == [own]
    assert submitted.downstream == [trigger, chained]
    assert missing.state == "Missing choice · position unchanged"
    assert missing.before == missing.after
    assert missing.downstream == []
    assert ending.state == "Ending · no choice required"
  end

  test "recipient grouping preserves exact renderer payloads and chunk order, including separate DM copy routes" do
    message = %{
      "recipient_id" => "123",
      "character_id" => 1,
      "delivery_audience" => "owner",
      "content" => " \nExact 🌍\n "
    }

    second = Map.put(message, "content", "Second")
    copy = Map.put(message, "delivery_audience", "dm_copy")
    groups = ReviewProjection.recipients(%{"players" => [message, second, copy]})
    owner = Enum.find(groups, &(&1.route == "owner"))
    assert owner.messages == [{message, 1}, {second, 2}]
    assert Enum.find(groups, &(&1.route == "dm_copy")).messages == [{copy, 1}]
    assert ReviewProjection.recipients(%{}) == []
  end
end
