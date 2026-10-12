defmodule AsyncWorlds.Ticks.QuestReview do
  @moduledoc "Pure frozen-target review validation and replay; no random generation."
  alias AsyncWorlds.Ticks.QuestDice

  def key(snapshot, input), do: QuestDice.identity(snapshot.revision, input, 0)

  def apply_operation(review, %{"type" => "reroll", "identity" => id, "new_value" => value}) do
    put_in(review, [Access.key("dice", %{}), id], value)
  end

  def apply_operation(review, %{"type" => type, "key" => key, "value" => value})
      when type in ["outcome", "player_narration"] do
    field = if type == "outcome", do: "outcomes", else: "narration"
    values = Map.get(review, field, %{})
    values = if is_nil(value), do: Map.delete(values, key), else: Map.put(values, key, value)
    if values == %{}, do: Map.delete(review, field), else: Map.put(review, field, values)
  end

  def validate(
        snapshot,
        %{"type" => type, "input_revision" => revision, "input" => input, "value" => value} = op
      )
      when type in ["outcome", "player_narration"] and map_size(op) == 4 do
    cond do
      revision != snapshot.revision ->
        {:error, :stale_input}

      input not in (get_in(snapshot.data, ["quest_inputs", "submissions"]) || []) ->
        {:error, :stale_identity}

      not valid_value?(snapshot, input, type, value) ->
        {:error, :invalid_edit}

      true ->
        {:ok, Map.put(op, "key", key(snapshot, input))}
    end
  end

  def validate(_, _), do: {:error, :invalid_edit}

  defp valid_value?(_, _, "player_narration", nil), do: true

  defp valid_value?(_, _, "player_narration", value),
    do:
      is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>) and
        String.trim(value) != "" and String.length(value) <= 2000

  defp valid_value?(snapshot, input, "outcome", value) do
    revisions = Map.new(snapshot.data["quest_inputs"]["revisions"], &{&1["id"], &1["definition"]})
    choice = QuestDice.choice(input, revisions)
    choice["mode"] == "rolled" and (is_nil(value) or value in ~w(failure partial success))
  end

  def valid?(snapshot, review) do
    dice = Map.get(review, "dice", %{})
    specs = QuestDice.specs(snapshot)
    inputs = get_in(snapshot.data, ["quest_inputs", "submissions"]) || []

    is_map(dice) and
      Enum.all?(dice, fn {id, value} ->
        Enum.any?(specs, &(&1["identity"] == id)) and is_integer(value) and value in 1..6
      end) and
      Enum.all?([{"outcomes", "outcome"}, {"narration", "player_narration"}], fn {field, type} ->
        values = Map.get(review, field, %{})

        is_map(values) and
          Enum.all?(values, fn {id, value} ->
            input = Enum.find(inputs, &(key(snapshot, &1) == id))
            input != nil and value != nil and valid_value?(snapshot, input, type, value)
          end)
      end)
  end

  def dice(rolls, review),
    do:
      Enum.map(rolls, fn roll ->
        Map.put(
          roll,
          "value",
          Map.get(Map.get(review, "dice", %{}), roll["identity"], roll["value"])
        )
      end)
end
