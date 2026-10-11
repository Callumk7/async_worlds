defmodule AsyncWorlds.QuestFixtures do
  def flag(value \\ true, visible \\ false),
    do: %{"type" => "boolean", "value" => value, "player_visible" => visible}

  def outcome(next, effects \\ []),
    do: %{"text" => "Result", "next_node" => next, "effects" => effects}

  def choice(id, next, effects \\ []) do
    %{
      "id" => id,
      "label" => id,
      "eligibility" => "disabled",
      "conditions" => [],
      "mode" => "fixed",
      "outcomes" => %{"fixed" => outcome(next, effects)}
    }
  end

  def definition do
    %{
      "start_node" => "hub",
      "nodes" => [
        %{
          "id" => "hub",
          "text" => "Hub",
          "ending" => false,
          "choices" => [
            choice("loop", "hub", [%{"type" => "set_flag", "key" => "secret", "flag" => flag()}]),
            choice("finish", "end", [%{"type" => "clear_flag", "key" => "secret"}])
          ]
        },
        %{"id" => "end", "text" => "Ending", "ending" => true, "choices" => []}
      ]
    }
  end

  def replace_choice(definition, choice) do
    [hub, ending] = definition["nodes"]
    put_in(definition["nodes"], [Map.put(hub, "choices", [choice]), ending])
  end

  def rolled do
    choice("roll", "hub")
    |> Map.merge(%{
      "mode" => "rolled",
      "dice" => 3,
      "outcomes" => %{
        "success" => outcome("end"),
        "partial" => outcome("hub"),
        "failure" => outcome("hub")
      },
      "critical_effects" => [
        %{"type" => "set_flag", "key" => "bonus", "flag" => flag(true, true)}
      ]
    })
  end
end
