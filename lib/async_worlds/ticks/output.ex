defmodule AsyncWorlds.Ticks.Output do
  @moduledoc "Shared exact preview/delivery renderer. Draft callers must authorize the DM."

  def render(payload, campaign) do
    public_clocks =
      payload["clocks"]
      |> Enum.reject(&(&1["visibility"] == "hidden"))
      |> Enum.map(fn clock ->
        if clock["visibility"] == "known",
          do: clock["name"],
          else: "#{clock["name"]}: #{clock["filled"]}/#{clock["segments"]}"
      end)

    dm_clocks =
      Enum.map(payload["clocks"], fn clock ->
        "#{clock["name"]}: #{clock["filled"]}/#{clock["segments"]}, paused=#{clock["paused"]}, completed=#{clock["completed"]}"
      end)

    title = "Tick #{payload["tick_number"]}"

    %{
      "public" =>
        messages(
          [title] ++ payload["world_news"] ++ public_clocks,
          "public",
          campaign["public_channel_id"]
        ),
      "dm" =>
        messages(
          [title] ++ payload["world_news"] ++ payload["dm_notifications"] ++ dm_clocks,
          "private",
          campaign["dm_user_id"]
        )
    }
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
