defmodule AsyncWorlds.Ticks.Output do
  @moduledoc "Shared exact preview/delivery renderer. Draft callers must authorize the DM."

  alias AsyncWorlds.Discord.ClockProgress

  def render(payload, campaign) do
    public_clocks =
      payload["clocks"]
      |> Enum.reject(&(&1["visibility"] == "hidden"))
      |> Enum.map(fn clock ->
        if clock["visibility"] == "known",
          do: clock["name"],
          else: "#{clock["name"]}: #{ClockProgress.render(clock["filled"], clock["segments"])}"
      end)

    dm_clocks =
      Enum.map(payload["clocks"], fn clock ->
        "#{clock["name"]}: #{ClockProgress.render(clock["filled"], clock["segments"])}, paused=#{clock["paused"]}, completed=#{clock["completed"]}"
      end)

    title = "Tick #{payload["tick_number"]}"

    events = payload["events"] || []
    event_lines = fn events -> Enum.map(events, &(&1["title"] <> " — " <> &1["text"])) end

    outputs = %{
      "public" =>
        messages(
          [title] ++
            event_lines.(Enum.filter(events, &(&1["audience"] == "public"))) ++
            payload["world_news"] ++ public_clocks,
          "public",
          campaign["public_channel_id"]
        ),
      "dm" =>
        messages(
          [title] ++
            event_lines.(events) ++
            payload["world_news"] ++ payload["dm_notifications"] ++ dm_clocks,
          "private",
          campaign["dm_user_id"]
        )
    }

    players =
      Enum.flat_map(payload["next_nodes"] || [], fn next ->
        id = next["character_id"]
        character = Enum.find(payload["characters"], &(&1["id"] == id))
        results = Enum.filter(payload["private_results"], &(&1["character_id"] == id))
        projection = next["projection"]

        result_lines =
          Enum.flat_map(results, fn result ->
            dice = Enum.filter(payload["rolls"], &(&1["input"] == result["input"]))

            summary =
              if dice == [],
                do: [],
                else: [
                  "Dice: #{Enum.map_join(dice, ", ", & &1["value"])} · #{result["outcome"]}#{if result["critical"], do: " · critical", else: ""}"
                ]

            summary ++ [result["text"]]
          end)

        lines =
          [title] ++ result_lines ++ AsyncWorlds.Discord.PlayerContent.quest_lines(projection)

        if payload["schema_version"] == 3 do
          payload["player_delivery"]["routes"]
          |> Enum.filter(&(&1["character_id"] == id))
          |> Enum.flat_map(fn route ->
            labelled = if route["label"], do: [route["label"] | lines], else: lines

            messages(labelled, "private", route["recipient_id"])
            |> Enum.with_index(fn message, chunk ->
              Map.merge(message, %{
                "character_id" => id,
                "delivery_audience" => route["audience"],
                "chunk_index" => chunk
              })
            end)
          end)
        else
          messages(lines, "private", character["discord_user_id"])
        end
      end)

    if players == [], do: outputs, else: Map.put(outputs, "players", players)
  end

  defp messages(lines, kind, recipient) do
    lines
    |> Enum.join("\n")
    |> AsyncWorlds.Discord.Content.chunks()
    |> Enum.map(fn chunk ->
      %{"kind" => kind, "recipient_id" => recipient, "content" => chunk}
    end)
  end
end
