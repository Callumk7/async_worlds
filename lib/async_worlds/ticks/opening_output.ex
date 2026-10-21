defmodule AsyncWorlds.Ticks.OpeningOutput do
  @moduledoc """
  Pure public opening briefing renderer. Accepts only the public activity whitelist.

  v4 adds Markdown headings, roster lists and scannable participation instructions.
  """
  alias AsyncWorlds.Discord.Content

  @version 4
  def version, do: @version

  @quest_instructions "### Quest choices\n" <>
                        "- Run `/quest` in the campaign guild for your private quest and available choices.\n" <>
                        "- While the tick is open, use its buttons to **submit or revise** a choice; **Clear** removes it.\n" <>
                        "- No resource assignment command is available. Missing choices do not incur a penalty."

  @tension_instructions "### How to take part\n" <>
                          "**Everyone can take part without a quest.**\n" <>
                          "- Each ongoing public Tension has its own discussion thread with an updated briefing and its tick and Tension IDs. Discuss plans there.\n" <>
                          "- Privately record what your character is trying to achieve with `/intent edit` and `/intent confirm` (`/intent view` lists your efforts).\n" <>
                          "- You can contribute to several Tensions, describe the people or assets you commit, and **revise or withdraw until the tick closes**.\n" <>
                          "- **Confirmation is not success:** the DM adjudicates the whole period and publishes what happened.\n" <>
                          "- `/chronicle list` shows the history."

  def render(number, channel, activities, narration, tension_participation \\ false)

  def render(number, channel, activities, narration, false) do
    lines(number, narration, roster_lines(activities), [@quest_instructions])
    |> messages(channel)
  end

  # Quest-free characters are not listed as having nothing to do; outstanding
  # quest decisions keep their roster line and /quest guidance.
  def render(number, channel, activities, narration, true) do
    quests = Enum.filter(activities, &(&1.decision_required == true))

    quest_lines =
      if quests == [], do: [], else: roster_lines(quests) ++ [@quest_instructions]

    lines(number, narration, [@tension_instructions], quest_lines)
    |> messages(channel)
  end

  defp lines(number, narration, body, footer),
    do: ["## Tick #{number} is opening."] ++ narration_lines(narration) ++ body ++ footer

  defp messages(lines, channel) do
    lines
    |> Enum.join("\n\n")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> Content.formatted_chunks()
    # Discord rejects content-only blank messages. Omit spacing-only chunks
    # before numbering/preview, never in the worker after content is reviewed.
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {content, index} ->
      %{id: index, chunk_index: index, kind: :public, recipient_id: channel, content: content}
    end)
  end

  defp narration_lines(""), do: []
  defp narration_lines(text), do: [text]

  defp roster_lines([]), do: ["No characters in this campaign; no quest decisions required."]

  defp roster_lines(activities),
    do: ["### Character activity\n" <> Enum.map_join(activities, "\n", &roster_line/1)]

  defp roster_line(activity) do
    requirement = requirement(activity)

    if activity.summary == requirement do
      "- #{activity.name}: #{activity.summary}"
    else
      "- #{activity.name}: #{activity.summary} — #{requirement}"
    end
  end

  defp requirement(%{decision_required: false}), do: "No quest decision required."

  defp requirement(%{dm_controlled: true}),
    do: "DM-controlled; the DM handles this quest decision."

  defp requirement(%{decision_required: true}),
    do: "Quest decision required; inspect available choices privately with `/quest`."
end
