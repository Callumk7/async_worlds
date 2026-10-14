defmodule AsyncWorlds.Ticks.OpeningOutputTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Ticks.OpeningOutput

  test "whitelist excludes private fields and explicitly includes every roster state" do
    rows = [
      %{
        name: "Scout",
        summary: "Public harbour work",
        decision_required: true,
        dm_controlled: false,
        text: "SECRET node",
        flags: %{"SECRET" => true},
        choices: ["SECRET choice"]
      },
      %{name: "Idle", summary: "No quest decision required.", decision_required: false},
      %{name: "DM", summary: "Public patrol", decision_required: true, dm_controlled: true}
    ]

    messages = OpeningOutput.render(7, "789", rows, "Opening narration")
    text = Enum.map_join(messages, "", & &1.content)
    assert text =~ "Tick 7"
    assert text =~ "Scout: Public harbour work — Quest decision required"
    assert text =~ "Idle: No quest decision required."
    refute text =~ "No quest decision required. No quest decision required."
    assert text =~ "DM handles this quest decision"
    assert text =~ "Opening narration"
    assert text =~ "/quest"
    assert text =~ "No resource assignment command"
    refute text =~ "SECRET"
    assert Enum.all?(messages, &(&1.recipient_id == "789" and &1.kind == :public))
  end

  test "public text canonicalizes CRLF and CR before chunking" do
    rows = [%{name: "Scout\rName", summary: "first\r\nsecond", decision_required: false}]

    text =
      OpeningOutput.render(1, "789", rows, "welcome\r\nnext\rlast")
      |> Enum.map_join("", & &1.content)

    refute text =~ "\r"
    assert text =~ "welcome\nnext\nlast"
    assert text =~ "Scout\nName: first\nsecond"
  end

  test "all Unicode chunks reconstruct the exact briefing without truncation" do
    narration = String.duplicate("🌍漢字é👩‍🚀\n", 700)
    messages = OpeningOutput.render(1, "789", [], narration)
    assert length(messages) > 3
    assert Enum.map(messages, & &1.chunk_index) == Enum.to_list(1..length(messages))

    assert Enum.all?(
             messages,
             &(String.valid?(&1.content) and length(String.codepoints(&1.content)) <= 1900)
           )

    text = Enum.map_join(messages, "", & &1.content)
    assert text =~ narration
    assert text =~ "No characters in this campaign"
    assert String.ends_with?(text, "Missing choices do not incur a penalty.")
  end
end
