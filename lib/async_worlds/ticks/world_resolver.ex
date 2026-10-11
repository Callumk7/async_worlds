defmodule AsyncWorlds.Ticks.WorldResolver do
  @moduledoc """
  Pure, deterministic quest and world resolution of frozen v1/v2 snapshots and recorded dice.

  Returns a DM-only JSON-compatible draft, never published state or deliveries.
  See docs/world-resolution.md for ordering, latching and extension boundaries.
  """
  alias AsyncWorlds.Ticks.{Snapshot, QuestDice}
  alias AsyncWorlds.Quests.Rules

  @phases ~w(quest_choices resource_assignments background_rates clock_triggers quest_conditions)

  def resolve(snapshot, review \\ %{}, rolls \\ [])

  def resolve(%Snapshot{schema_version: 1, revision: revision, data: data}, review, [])
      when is_binary(revision) and byte_size(revision) > 0 and is_map(data) do
    if valid?(data) and valid_review?(review, data["clocks"]) do
      payload = run(data, revision, review)
      payload = if map_size(review) == 0, do: payload, else: Map.put(payload, "review", review)
      {:ok, payload}
    else
      {:error, :invalid_snapshot}
    end
  end

  def resolve(
        %Snapshot{schema_version: 2, revision: revision, data: data} = snapshot,
        review,
        rolls
      )
      when is_map(data) and is_binary(revision) and byte_size(revision) > 0 do
    cond do
      not valid_v2?(data) or not valid_review?(review, data["clocks"]) ->
        {:error, :invalid_snapshot}

      not QuestDice.valid?(snapshot, rolls) ->
        {:error, :invalid_rolls}

      true ->
        payload = run(data, revision, review, rolls)
        payload = if map_size(review) == 0, do: payload, else: Map.put(payload, "review", review)

        if Enum.all?(payload["characters"], &AsyncWorlds.Characters.Flags.valid?(&1["flags"])),
          do: {:ok, payload},
          else: {:error, :invalid_flags}
    end
  end

  def resolve(_, _, _), do: {:error, :invalid_snapshot}

  def valid_snapshot?(snapshot) do
    case snapshot do
      %Snapshot{schema_version: 1, data: data} -> valid?(data)
      %Snapshot{schema_version: 2, data: data} -> valid_v2?(data)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_v2?(data) do
    world =
      Map.update!(data, "clocks", fn clocks ->
        Enum.map(clocks, fn clock ->
          Map.update!(clock, "triggers", fn triggers ->
            Enum.reject(triggers, &(&1["type"] in ["set_flag", "unlock_quest"]))
          end)
        end)
      end)

    valid?(world) and AsyncWorlds.Quests.FrozenInputs.valid?(data["quest_inputs"], data["clocks"])
  rescue
    _ -> false
  end

  defp valid_review?(review, clocks) when is_map(review) do
    ids = Enum.map(clocks, &to_string(&1["id"]))
    deltas = Map.get(review, "clock_deltas", %{})
    news = Map.get(review, "world_news", [])

    Enum.all?(Map.keys(review), &(&1 in ["clock_deltas", "world_news"])) and
      is_map(deltas) and
      Enum.all?(deltas, fn {id, delta} ->
        id in ids and is_integer(delta) and
          not Enum.find(clocks, &(to_string(&1["id"]) == id))["completed"]
      end) and is_list(news) and length(news) <= 100 and
      Enum.all?(news, &(is_binary(&1) and String.trim(&1) != "" and String.length(&1) <= 2000))
  end

  defp valid_review?(_, _), do: false

  defp valid?(data) do
    with %{"id" => campaign_id} when is_integer(campaign_id) <- data["campaign"],
         number when is_integer(number) and number > 0 <- data["tick_number"],
         clocks when is_list(clocks) <- data["clocks"],
         true <- Enum.all?(clocks, &valid_clock?(&1, campaign_id)),
         ids = Enum.map(clocks, & &1["id"]),
         true <- length(Enum.uniq(ids)) == length(ids),
         %{"clocks" => order, "race_tie_break" => "ascending_clock_id", "phases" => @phases} <-
           data["ordering"],
         true <- order == Enum.sort(ids),
         true <- valid_races?(clocks) do
      Enum.all?(clocks, fn clock ->
        Enum.all?(clock["triggers"], &valid_trigger?(&1, clock["id"], ids))
      end)
    else
      _ -> false
    end
  end

  defp valid_clock?(clock, campaign_id) when is_map(clock) do
    is_integer(clock["id"]) and clock["id"] > 0 and
      clock["campaign_id"] == campaign_id and is_binary(clock["name"]) and
      clock["segments"] in [4, 6, 8] and is_integer(clock["filled"]) and
      clock["filled"] >= 0 and clock["filled"] <= clock["segments"] and
      is_integer(clock["background_rate"]) and is_boolean(clock["paused"]) and
      is_boolean(clock["completed"]) and clock["visibility"] in ~w(public known hidden) and
      (is_nil(clock["racing_group"]) or
         (is_binary(clock["racing_group"]) and clock["racing_group"] != "")) and
      is_list(clock["triggers"])
  end

  defp valid_clock?(_, _), do: false

  defp valid_races?(clocks) do
    clocks
    |> Enum.reject(&is_nil(&1["racing_group"]))
    |> Enum.group_by(& &1["racing_group"])
    |> Enum.all?(fn {_group, members} ->
      length(members) == 2 and length(Enum.uniq_by(members, & &1["completed"])) == 1
    end)
  end

  defp valid_trigger?(%{"type" => type, "text" => text} = trigger, _id, _ids)
       when type in ["notify_dm", "world_news"] do
    is_binary(text) and String.trim(text) != "" and String.length(text) <= 2000 and
      is_nil(trigger["clock_id"])
  end

  defp valid_trigger?(%{"type" => "start_clock", "clock_id" => target} = trigger, id, ids),
    do: target in ids and target != id and is_nil(trigger["text"])

  defp valid_trigger?(_, _, _), do: false

  defp run(data, revision, review, rolls \\ []) do
    order = data["ordering"]["clocks"]

    state = %{
      clocks: Map.new(data["clocks"], &{&1["id"], &1}),
      latched: MapSet.new(),
      races: %{},
      log: [],
      sequence: 0,
      tick: data["tick_number"],
      deltas: Map.get(review, "clock_deltas", %{}),
      characters: Map.new(get_in(data, ["quest_inputs", "characters"]) || [], &{&1["id"], &1}),
      progressions:
        Map.new(get_in(data, ["quest_inputs", "progressions"]) || [], &{&1["character_id"], &1}),
      unlocked: %{}
    }

    state = Enum.reduce(order, state, &latch/2)
    state = quests(state, data["quest_inputs"], rolls)
    state = Enum.reduce(order, state, &background/2)
    state = Enum.reduce(order, state, &complete/2)
    log = Enum.reverse(state.log)
    triggers = Enum.filter(log, &(&1["kind"] == "trigger_result"))

    payload = %{
      "schema_version" => 1,
      "input_revision" => revision,
      "tick_number" => state.tick,
      "clocks" => Enum.map(order, &Map.fetch!(state.clocks, &1)),
      "race_winners" =>
        state.races
        |> Enum.map(fn {group, id} -> %{"racing_group" => group, "clock_id" => id} end)
        |> Enum.sort_by(& &1["clock_id"]),
      "effects" => Enum.filter(log, &(&1["kind"] == "clock_change")),
      "trigger_results" => triggers,
      "log" => log,
      "world_news" => Map.get(review, "world_news", intents(triggers, "world_news")),
      "dm_notifications" => intents(triggers, "notify_dm")
    }

    if data["quest_inputs"] do
      Map.merge(payload, %{
        "schema_version" => 2,
        "rolls" => rolls,
        "characters" => state.characters |> Map.values() |> Enum.sort_by(& &1["id"]),
        "progressions" => state.progressions |> Map.values() |> Enum.sort_by(& &1["id"]),
        "unlocked_quests" =>
          state.unlocked
          |> Enum.sort()
          |> Enum.map(fn {id, quests} ->
            %{"character_id" => id, "quest_ids" => Enum.sort(quests)}
          end),
        "private_results" => Enum.filter(log, &(&1["kind"] == "quest_result")),
        "next_nodes" => next_nodes(state, data["quest_inputs"])
      })
    else
      payload
    end
  end

  defp quests(state, nil, _), do: state

  defp quests(state, inputs, rolls) do
    revisions = Map.new(inputs["revisions"], &{&1["id"], &1["definition"]})

    Enum.reduce(inputs["submissions"], state, fn submission, acc ->
      choice = QuestDice.choice(submission, revisions)
      dice = Enum.filter(rolls, &(&1["input"] == submission))
      {:ok, outcome, critical} = Rules.outcome(choice, Enum.map(dice, & &1["value"]))
      result = choice["outcomes"][outcome]

      source =
        "quest:tick:#{acc.tick}:character:#{submission["character_id"]}:choice:#{submission["choice_id"]}"

      acc =
        Enum.reduce(dice, acc, fn die, acc ->
          entry(
            acc,
            Map.merge(die, %{"kind" => "roll", "phase" => "quest_choices", "source" => source})
          )
        end)

      effects = result["effects"] ++ if(critical, do: choice["critical_effects"], else: [])

      acc =
        effects
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {effect, index}, acc ->
          effect_source = "#{source}:effect:#{index}"
          acc = quest_effect(acc, submission["character_id"], effect, effect_source)

          entry(acc, %{
            "kind" => "quest_effect",
            "character_id" => submission["character_id"],
            "effect" => effect,
            "source" => effect_source,
            "phase" => "quest_choices"
          })
        end)

      progression = acc.progressions[submission["character_id"]]
      next = Rules.node(revisions[submission["revision_id"]], result["next_node"])

      updated =
        Map.merge(progression, %{
          "node_id" => next["id"],
          "status" => if(next["ending"], do: "completed", else: "active"),
          "position_version" =>
            progression["position_version"] +
              if(next["id"] == progression["node_id"], do: 0, else: 1)
        })

      acc = %{acc | progressions: Map.put(acc.progressions, submission["character_id"], updated)}

      entry(acc, %{
        "kind" => "quest_result",
        "phase" => "quest_choices",
        "source" => source,
        "character_id" => submission["character_id"],
        "input" => submission,
        "outcome" => outcome,
        "critical" => critical,
        "text" => result["text"],
        "before" => progression,
        "after" => updated
      })
    end)
  end

  defp quest_effect(
         state,
         _id,
         %{"type" => "clock_delta", "clock_id" => id, "delta" => delta},
         source
       ) do
    before = state.clocks[id]

    updated =
      if before["completed"],
        do: before,
        else: Map.put(before, "filled", max(0, min(before["segments"], before["filled"] + delta)))

    state
    |> change(before, updated, source, "quest_choices", %{
      "requested_delta" => delta,
      "applied_delta" => updated["filled"] - before["filled"]
    })
    |> then(&latch(id, &1))
  end

  defp quest_effect(state, id, effect, source) do
    before = state.characters[id]

    flags =
      if effect["type"] == "set_flag",
        do: Map.put(before["flags"], effect["key"], effect["flag"]),
        else: Map.delete(before["flags"], effect["key"])

    character_change(state, before, Map.put(before, "flags", flags), source, "quest_choices")
  end

  defp character_change(state, before, updated, source, phase) do
    if before == updated do
      state
    else
      state = %{state | characters: Map.put(state.characters, before["id"], updated)}

      entry(state, %{
        "kind" => "character_change",
        "character_id" => before["id"],
        "before" => before,
        "after" => updated,
        "source" => source,
        "phase" => phase
      })
    end
  end

  defp next_nodes(state, inputs) do
    revisions = Map.new(inputs["revisions"], &{&1["id"], &1["definition"]})
    clocks = Map.new(state.clocks, fn {id, c} -> {id, %{filled: c["filled"]}} end)

    state.progressions
    |> Enum.sort()
    |> Enum.map(fn {id, p} ->
      status = if p["status"] == "completed", do: :completed, else: :active

      projection =
        Rules.project(revisions[p["revision_id"]], %{
          node_id: p["node_id"],
          status: status,
          flags: state.characters[id]["flags"],
          clocks: clocks
        })

      %{"character_id" => id, "projection" => Jason.decode!(Jason.encode!(projection))}
    end)
  end

  defp intents(triggers, type),
    do: triggers |> Enum.filter(&(&1["type"] == type)) |> Enum.map(& &1["text"])

  defp latch(id, state) do
    clock = Map.fetch!(state.clocks, id)
    group = clock["racing_group"]

    cond do
      clock["completed"] or clock["filled"] != clock["segments"] ->
        state

      group && Map.has_key?(state.races, group) ->
        state

      true ->
        races = if group, do: Map.put(state.races, group, id), else: state.races
        %{state | latched: MapSet.put(state.latched, id), races: races}
    end
  end

  defp background(id, state) do
    clock = Map.fetch!(state.clocks, id)

    override = Map.get(state.deltas, to_string(id))
    delta = override || clock["background_rate"]

    if (clock["paused"] and is_nil(override)) or clock["completed"] do
      state
    else
      updated =
        Map.put(
          clock,
          "filled",
          max(0, min(clock["segments"], clock["filled"] + delta))
        )

      source =
        if is_nil(override),
          do: "background:tick:#{state.tick}",
          else: "review:tick:#{state.tick}:clock:#{id}"

      state
      |> change(clock, updated, source, "background_rates", %{
        "requested_delta" => delta,
        "applied_delta" => updated["filled"] - clock["filled"]
      })
      |> then(&latch(id, &1))
    end
  end

  defp complete(id, state) do
    if MapSet.member?(state.latched, id) do
      clock = Map.fetch!(state.clocks, id)
      source = "completion:tick:#{state.tick}:clock:#{id}"
      state = change(state, clock, Map.put(clock, "completed", true), source, "clock_triggers")

      state =
        if clock["racing_group"] do
          loser =
            Enum.find_value(state.clocks, fn {other_id, other} ->
              if other_id != id and other["racing_group"] == clock["racing_group"], do: other
            end)

          change(state, loser, Map.put(loser, "completed", true), source, "clock_triggers")
        else
          state
        end

      clock["triggers"]
      |> Enum.with_index()
      |> Enum.reduce(state, fn {trigger, index}, acc -> trigger(acc, id, trigger, index) end)
    else
      state
    end
  end

  defp trigger(state, id, trigger, index) do
    source = "trigger:tick:#{state.tick}:clock:#{id}:#{index}"
    result = Map.merge(trigger, %{"clock_id" => id, "trigger_index" => index})

    {state, result} =
      cond do
        trigger["type"] == "set_flag" ->
          character = state.characters[trigger["character_id"]]
          updated = put_in(character, ["flags", trigger["key"]], trigger["flag"])
          state = character_change(state, character, updated, source, "clock_triggers")
          {state, Map.put(result, "changed", character != updated)}

        trigger["type"] == "unlock_quest" ->
          id = trigger["character_id"]
          quests = Map.get(state.unlocked, id, [])
          changed = trigger["quest_id"] not in quests
          quests = Enum.uniq(quests ++ [trigger["quest_id"]])

          {%{state | unlocked: Map.put(state.unlocked, id, quests)},
           Map.put(result, "changed", changed)}

        trigger["type"] == "start_clock" ->
          target = Map.fetch!(state.clocks, trigger["clock_id"])
          updated = if target["completed"], do: target, else: Map.put(target, "paused", false)
          state = change(state, target, updated, source, "clock_triggers")

          {state,
           Map.merge(result, %{"target_clock_id" => target["id"], "changed" => target != updated})}

        true ->
          {state, result}
      end

    entry(
      state,
      Map.merge(result, %{
        "kind" => "trigger_result",
        "source" => source,
        "phase" => "clock_triggers"
      })
    )
  end

  defp change(state, before, after_clock, source, phase, extra \\ %{}) do
    if before == after_clock do
      state
    else
      state = %{state | clocks: Map.put(state.clocks, before["id"], after_clock)}

      entry(
        state,
        Map.merge(extra, %{
          "kind" => "clock_change",
          "clock_id" => before["id"],
          "source" => source,
          "phase" => phase,
          "before" => before,
          "after" => after_clock
        })
      )
    end
  end

  defp entry(state, event) do
    sequence = state.sequence + 1
    %{state | sequence: sequence, log: [Map.put(event, "sequence", sequence) | state.log]}
  end
end
