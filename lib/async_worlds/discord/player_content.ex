defmodule AsyncWorlds.Discord.PlayerContent do
  @moduledoc "Player-safe text from authorized quest projections only; never raw definitions or effects."

  def quest_lines(%{text: text, choices: choices, completed: completed}) do
    [text] ++
      Enum.map(choices, &choice_line/1) ++ if(completed, do: ["Quest completed."], else: [])
  end

  def quest_lines(%{"text" => text, "choices" => choices} = projection) do
    [text] ++
      Enum.map(choices, &choice_line/1) ++
      if(projection["completed"], do: ["Quest completed."], else: [])
  end

  def messages(lines, recipient) do
    lines
    |> Enum.join("\n")
    |> AsyncWorlds.Discord.Content.chunks()
    |> Enum.map(&%{"kind" => "private", "recipient_id" => recipient, "content" => &1})
  end

  def choice_line(%{label: label, enabled: enabled}), do: label <> unavailable(enabled)
  def choice_line(%{"label" => label, "enabled" => enabled}), do: label <> unavailable(enabled)
  defp unavailable(true), do: ""
  defp unavailable(_), do: " — Not available right now."
end
