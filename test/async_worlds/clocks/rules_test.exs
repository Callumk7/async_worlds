defmodule AsyncWorlds.Clocks.RulesTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Clocks.{Clock, Rules, Trigger}

  test "signed background rates, bounds, pause and completion are pure" do
    clock = %Clock{segments: 4, filled: 2, background_rate: -9}
    assert Rules.background(clock).filled == 0
    assert Rules.background(%{clock | background_rate: 9}).filled == 4
    assert Rules.background(%{clock | paused: true}).filled == 2
    assert Rules.background(%{clock | completed: true}).filled == 2
    assert clock.filled == 2
    assert Rules.adjust(clock, 99).filled == 4
  end

  test "starting preserves progress/rate, does not resurrect completed clocks" do
    clock = %Clock{segments: 6, filled: 3, paused: true, background_rate: 2}
    assert Rules.start(clock) == %{clock | paused: false}
    completed = %{clock | completed: true}
    assert Rules.start(completed) == completed
    assert Rules.reset(completed) == %{completed | filled: 0, completed: false}
  end

  test "completion returns winner effects only and cannot repeat" do
    winner = %Clock{segments: 4, filled: 4, triggers: [%Trigger{type: :world_news, text: "Win"}]}
    loser = %Clock{segments: 4, filled: 1, triggers: [%Trigger{type: :notify_dm, text: "Lose"}]}
    {done, lost, actions} = Rules.complete(winner, loser)
    assert done.completed and lost.completed
    assert actions == winner.triggers
    assert Rules.complete(done, lost) == {done, lost, []}
    assert Rules.complete(%{winner | filled: 3}, nil) == {%{winner | filled: 3}, nil, []}
    assert Rules.complete(winner, nil) == {%{winner | completed: true}, nil, winner.triggers}
  end
end
