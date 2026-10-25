defmodule AsyncWorlds.Discord.ClockProgress do
  @moduledoc "Shared segmented text progress for Discord clock displays."

  def render(filled, segments) do
    "`#{String.duplicate("▰", filled)}#{String.duplicate("▱", segments - filled)}` #{filled}/#{segments}"
  end
end
