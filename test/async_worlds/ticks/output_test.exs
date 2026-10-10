defmodule AsyncWorlds.Ticks.OutputTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Ticks.Output

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
