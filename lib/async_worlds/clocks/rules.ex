defmodule AsyncWorlds.Clocks.Rules do
  @moduledoc "Pure helpers for frozen draft inputs; never perform persistence or delivery."

  def adjust(%{completed: true} = clock, delta) when is_integer(delta), do: clock

  def adjust(clock, delta) when is_integer(delta) do
    %{clock | filled: max(0, min(clock.segments, clock.filled + delta))}
  end

  def background(%{paused: true} = clock), do: clock
  def background(clock), do: adjust(clock, clock.background_rate)
  def reset(clock), do: %{clock | filled: 0, completed: false}

  def start(%{completed: true} = clock), do: clock
  def start(clock), do: %{clock | paused: false}

  @doc "Completes a filled winner and its racing loser; only the winner's actions are returned."
  def complete(%{completed: false, filled: filled, segments: filled} = winner, loser) do
    {%{winner | completed: true}, complete_loser(loser), winner.triggers}
  end

  def complete(winner, loser), do: {winner, loser, []}

  defp complete_loser(nil), do: nil
  defp complete_loser(clock), do: %{clock | completed: true}
end
