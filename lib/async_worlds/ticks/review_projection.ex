defmodule AsyncWorlds.Ticks.ReviewProjection do
  @moduledoc "DM-only presentation of canonical frozen/draft consequences; never a delivery renderer."

  def players(payload, snapshot) do
    inputs = snapshot.data["quest_inputs"] || %{}
    invalidated = MapSet.new(inputs["invalidations"] || [], & &1["character_id"])

    Enum.map(inputs["characters"] || [], fn before ->
      id = before["id"]
      result = Enum.find(payload["private_results"] || [], &(&1["character_id"] == id))
      after_character = Enum.find(payload["characters"], &(&1["id"] == id))
      progression = Enum.find(inputs["progressions"], &(&1["character_id"] == id))
      next = Enum.find(payload["next_nodes"], &(&1["character_id"] == id))
      source = if result, do: result["source"] <> ":", else: nil

      %{
        id: id,
        name: before["name"],
        submitted?: result != nil,
        state:
          cond do
            result && result["after"]["status"] == "completed" ->
              "Submitted · ending"

            result ->
              "Submitted"

            MapSet.member?(invalidated, id) ->
              "Invalidated choice · position unchanged"

            progression && progression["status"] in ["completed", "ended"] ->
              "Ending · no choice required"

            progression ->
              "Missing choice · position unchanged"

            true ->
              "No active quest"
          end,
        before: progression,
        after: Enum.find(payload["progressions"], &(&1["character_id"] == id)),
        flags_before: before["flags"],
        flags_after: after_character["flags"],
        next: if(next, do: next["projection"]),
        consequences:
          Enum.filter(payload["log"], fn event ->
            event["character_id"] == id or
              (result != nil and event["source"] == result["source"]) or
              (source != nil and String.starts_with?(event["source"], source))
          end),
        downstream: downstream(payload, source)
      }
    end)
  end

  # Show shared clock traces, not a claim that one player alone caused completion.
  defp downstream(_payload, nil), do: []

  defp downstream(payload, source) do
    ids =
      payload["effects"]
      |> Enum.filter(&String.starts_with?(&1["source"], source))
      |> Enum.map(& &1["clock_id"])
      |> MapSet.new()

    ids = downstream_ids(payload["trigger_results"], ids)
    Enum.filter(payload["log"], &(&1["clock_id"] in ids && &1["phase"] != "quest_choices"))
  end

  defp downstream_ids(triggers, ids) do
    expanded =
      Enum.reduce(triggers, ids, fn trigger, acc ->
        if trigger["clock_id"] in acc && trigger["target_clock_id"],
          do: MapSet.put(acc, trigger["target_clock_id"]),
          else: acc
      end)

    if expanded == ids, do: ids, else: downstream_ids(triggers, expanded)
  end

  def clock_events(payload, id),
    do: Enum.filter(payload["log"], &(&1["clock_id"] == id))

  def source_label(%{"kind" => "roll"}), do: "Recorded roll"
  def source_label(%{"kind" => "quest_result"}), do: "Quest outcome"
  def source_label(%{"phase" => "quest_choices"}), do: "Quest effect"
  def source_label(%{"phase" => "background_rates"}), do: "Background delta"
  def source_label(_), do: "Completion / trigger"

  def summary(%{"kind" => "clock_change"} = event) do
    delta =
      if event["requested_delta"],
        do: " · requested #{event["requested_delta"]}, applied #{event["applied_delta"]}",
        else: ""

    "Clock ##{event["clock_id"]}: #{event["before"]["filled"]} → #{event["after"]["filled"]}#{delta} · completed #{event["before"]["completed"]} → #{event["after"]["completed"]} · paused #{event["before"]["paused"]} → #{event["after"]["paused"]}"
  end

  def summary(%{"kind" => "trigger_result"} = event),
    do:
      "Fired #{event["type"]} · #{event["text"] || Jason.encode!(Map.take(event, ~w(target_clock_id character_id quest_id key changed)))}"

  def summary(%{"kind" => "character_change"} = event),
    do:
      "Flags: #{Jason.encode!(event["before"]["flags"])} → #{Jason.encode!(event["after"]["flags"])}"

  def summary(%{"kind" => "quest_effect", "effect" => effect}), do: Jason.encode!(effect)
  def summary(%{"kind" => "roll", "value" => value}), do: "Recorded die: #{value}"
  def summary(%{"kind" => "quest_result", "outcome" => outcome}), do: "Outcome: #{outcome}"

  def recipients(outputs) do
    for audience <- ~w(dm players),
        {route, messages} <-
          Enum.group_by(
            outputs[audience] || [],
            &{&1["recipient_id"], &1["character_id"], &1["delivery_audience"]}
          )
          |> Enum.sort() do
      {recipient, character, delivery_audience} = route

      %{
        id: "#{audience}-#{recipient}-#{character}-#{delivery_audience}",
        audience: audience,
        recipient: recipient,
        character: character,
        route: delivery_audience,
        messages: Enum.with_index(messages, 1)
      }
    end
  end
end
