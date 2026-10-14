defmodule AsyncWorlds.Ticks.OpeningOutput do
  @moduledoc "Pure public opening briefing renderer. Accepts only the public activity whitelist."
  alias AsyncWorlds.Discord.Content

  @version 1
  def version, do: @version

  def render(number, channel, activities, narration) do
    lines =
      ["Tick #{number} is opening."] ++
        narration_lines(narration) ++
        roster_lines(activities) ++
        [
          "Run /quest in the campaign guild for your private quest and available choices. " <>
            "While the tick is open, use its buttons to submit or revise a choice; Clear removes it. " <>
            "No resource assignment command is available. Missing choices do not incur a penalty."
        ]

    lines
    |> Enum.join("\n\n")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> Content.unicode_chunks()
    |> Enum.with_index(1)
    |> Enum.map(fn {content, index} ->
      %{id: index, chunk_index: index, kind: :public, recipient_id: channel, content: content}
    end)
  end

  defp narration_lines(""), do: []
  defp narration_lines(text), do: [text]

  defp roster_lines([]), do: ["No characters in this campaign; no quest decisions required."]

  defp roster_lines(activities) do
    Enum.map(activities, fn activity ->
      requirement = requirement(activity)

      if activity.summary == requirement do
        "#{activity.name}: #{activity.summary}"
      else
        "#{activity.name}: #{activity.summary} — #{requirement}"
      end
    end)
  end

  defp requirement(%{decision_required: false}), do: "No quest decision required."

  defp requirement(%{dm_controlled: true}),
    do: "DM-controlled; the DM handles this quest decision."

  defp requirement(%{decision_required: true}),
    do: "Quest decision required; inspect available choices privately with /quest."
end
