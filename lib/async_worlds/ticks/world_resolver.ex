defmodule AsyncWorlds.Ticks.WorldResolver do
  @moduledoc """
  Pure, deterministic world-only resolution of version-1 frozen snapshots.

  Returns a DM-only JSON-compatible draft, never published state or deliveries.
  See docs/world-resolution.md for ordering, latching and extension boundaries.
  """
  alias AsyncWorlds.Ticks.Snapshot

  @phases ~w(quest_choices resource_assignments background_rates clock_triggers quest_conditions)

  def resolve(snapshot, review \\ %{})

  def resolve(%Snapshot{schema_version: 1, revision: revision, data: data}, review)
      when is_binary(revision) and byte_size(revision) > 0 and is_map(data) do
    if valid?(data) and valid_review?(review, data["clocks"]) do
      payload = run(data, revision, review)
      payload = if map_size(review) == 0, do: payload, else: Map.put(payload, "review", review)
      {:ok, payload}
    else
      {:error, :invalid_snapshot}
    end
  end

  def resolve(_, _), do: {:error, :invalid_snapshot}

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

  defp run(data, revision, review) do
    order = data["ordering"]["clocks"]

    state = %{
      clocks: Map.new(data["clocks"], &{&1["id"], &1}),
      latched: MapSet.new(),
      races: %{},
      log: [],
      sequence: 0,
      tick: data["tick_number"],
      deltas: Map.get(review, "clock_deltas", %{})
    }

    state = Enum.reduce(order, state, &latch/2)
    state = Enum.reduce(order, state, &background/2)
    state = Enum.reduce(order, state, &complete/2)
    log = Enum.reverse(state.log)
    triggers = Enum.filter(log, &(&1["kind"] == "trigger_result"))

    %{
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
      if trigger["type"] == "start_clock" do
        target = Map.fetch!(state.clocks, trigger["clock_id"])
        updated = if target["completed"], do: target, else: Map.put(target, "paused", false)
        state = change(state, target, updated, source, "clock_triggers")

        {state,
         Map.merge(result, %{"target_clock_id" => target["id"], "changed" => target != updated})}
      else
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
