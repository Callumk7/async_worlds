defmodule AsyncWorlds.Ticks.OutputTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Ticks.Output

  test "tick summaries render clock bars while preserving public visibility" do
    clocks =
      for {name, filled, visibility} <- [
            {"Escape the castle", 4, "public"},
            {"Sample Clock", 3, "public"},
            {"Empty", 0, "public"},
            {"Known", 2, "known"},
            {"Secret", 1, "hidden"}
          ] do
        %{
          "name" => name,
          "filled" => filled,
          "segments" => 4,
          "visibility" => visibility,
          "paused" => false,
          "completed" => filled == 4
        }
      end

    outputs =
      Output.render(
        %{"tick_number" => 4, "world_news" => [], "dm_notifications" => [], "clocks" => clocks},
        %{"dm_user_id" => "456", "public_channel_id" => "789"}
      )

    public = Enum.map_join(outputs["public"], "", & &1["content"])
    dm = Enum.map_join(outputs["dm"], "", & &1["content"])

    assert public ==
             "Tick 4\nEscape the castle: `▰▰▰▰` 4/4\nSample Clock: `▰▰▰▱` 3/4\nEmpty: `▱▱▱▱` 0/4\nKnown"

    assert dm =~ "Escape the castle: `▰▰▰▰` 4/4"
    assert dm =~ "Sample Clock: `▰▰▰▱` 3/4"
    assert dm =~ "Known: `▰▰▱▱` 2/4"
    assert dm =~ "Secret: `▰▱▱▱` 1/4"
  end

  test "large Unicode narration splits deterministically into bounded exact messages" do
    news = String.duplicate("🌍", 2000)

    payload = %{
      "tick_number" => 1,
      "world_news" => [news, news],
      "dm_notifications" => ["Private"],
      "clocks" => [
        %{
          "name" => "Hidden",
          "visibility" => "hidden",
          "filled" => 4,
          "segments" => 4,
          "paused" => false,
          "completed" => true
        },
        %{
          "name" => "Known",
          "visibility" => "known",
          "filled" => 3,
          "segments" => 6,
          "paused" => false,
          "completed" => false
        }
      ]
    }

    campaign = %{"dm_user_id" => "456", "public_channel_id" => "789"}
    outputs = Output.render(payload, campaign)
    assert outputs == Output.render(payload, campaign)
    assert length(outputs["public"]) == 3

    assert Enum.map_join(outputs["public"], "", & &1["content"]) ==
             "Tick 1\n#{news}\n#{news}\nKnown"

    for {_, messages} <- outputs, message <- messages do
      assert length(String.codepoints(message["content"])) <= 1900
      assert String.valid?(message["content"])
    end

    assert Enum.all?(outputs["public"], &(&1["kind"] == "public" and &1["recipient_id"] == "789"))
    assert Enum.all?(outputs["dm"], &(&1["kind"] == "private" and &1["recipient_id"] == "456"))
  end
end
