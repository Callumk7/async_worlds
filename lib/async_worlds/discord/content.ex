defmodule AsyncWorlds.Discord.Content do
  @moduledoc "Discord-safe content chunks measured in Unicode codepoints, not bytes."

  def chunks(content) when is_binary(content) do
    content
    |> String.codepoints()
    |> Enum.chunk_every(1900)
    |> Enum.map(&Enum.join/1)
  end
end
