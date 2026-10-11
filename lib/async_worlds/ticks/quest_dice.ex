defmodule AsyncWorlds.Ticks.QuestDice do
  @moduledoc "Pure stable die identities and frozen associations; no randomness or persistence."
  alias AsyncWorlds.Quests.Rules

  def specs(%{schema_version: 1}), do: []

  def specs(snapshot) do
    inputs = snapshot.data["quest_inputs"]
    revisions = Map.new(inputs["revisions"], &{&1["id"], &1["definition"]})

    Enum.flat_map(inputs["submissions"], fn submission ->
      choice = choice(submission, revisions)

      if choice["mode"] == "rolled" do
        for index <- 0..(choice["dice"] - 1) do
          %{
            "identity" => identity(snapshot.revision, submission, index),
            "input" => submission,
            "die_index" => index
          }
        end
      else
        []
      end
    end)
  end

  def choice(submission, revisions) do
    revisions[submission["revision_id"]]
    |> Rules.node(submission["node_id"])
    |> Map.fetch!("choices")
    |> Enum.find(&(&1["id"] == submission["choice_id"]))
  end

  def identity(revision, s, index) do
    # JSON tuple avoids delimiter collisions in author-supplied node/choice IDs.
    Jason.encode!([
      revision,
      s["character_id"],
      s["progression_id"],
      s["revision_id"],
      s["node_id"],
      s["position_version"],
      s["choice_id"],
      index
    ])
  end

  def valid?(snapshot, rolls) when is_list(rolls) do
    expected = specs(snapshot)

    length(rolls) == length(expected) and
      Enum.zip(expected, rolls)
      |> Enum.all?(fn {spec, roll} ->
        is_map(roll) and Map.drop(roll, ["value"]) == spec and is_integer(roll["value"]) and
          roll["value"] in 1..6
      end)
  end

  def valid?(_, _), do: false
end
