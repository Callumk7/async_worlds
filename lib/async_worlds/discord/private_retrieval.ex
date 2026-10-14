defmodule AsyncWorlds.Discord.PrivateRetrieval do
  @moduledoc "Discord presentation of shared, subject-authorized personal history."
  alias AsyncWorlds.Ticks.PersonalHistory

  def result(guild, access) do
    with {:ok, history} <- PersonalHistory.result(guild, access) do
      content =
        case history do
          nil -> "No published personal result yet."
          %{content_chunks: chunks} -> Enum.join(chunks, "")
        end

      {:ok, content}
    end
  end

  def submission(guild, access) do
    with {:ok, history} <- PersonalHistory.submission(guild, access) do
      content =
        case history do
          nil ->
            :no_submission

          %{tick_number: number, choice_label: label} ->
            "Tick #{number} — Latest choice: #{label} (closed). Use /quest for your current quest and /result for your approved result."
        end

      {:ok, content}
    end
  end
end
