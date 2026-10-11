defmodule AsyncWorlds.Quests.Rules do
  @moduledoc "Pure frozen-input transition helper. Does not mutate persisted or published player state."
  alias AsyncWorlds.Quests.Definition
  alias AsyncWorlds.Characters.Flags

  def node(definition, id), do: Enum.find(definition["nodes"], &(&1["id"] == id))

  def eligible?(choice, flags, clocks),
    do: Enum.all?(choice["conditions"], &met?(&1, flags, clocks))

  defp met?(
         %{"type" => "character_flag", "key" => key, "flag_type" => type, "value" => value},
         flags,
         _
       ) do
    case Map.get(flags, key) do
      %{"type" => ^type, "value" => ^value} -> true
      _ -> false
    end
  end

  defp met?(
         %{"type" => "clock_threshold", "clock_id" => id, "operator" => op, "value" => value},
         _,
         clocks
       ) do
    case Map.get(clocks, id) do
      nil -> false
      clock -> if op == "gte", do: clock.filled >= value, else: clock.filled <= value
    end
  end

  def transition(definition, state, choice_id, dice \\ []) do
    with true <- valid_state?(definition, state),
         :active <- state.status,
         current when not is_nil(current) <- node(definition, state.node_id),
         choice when not is_nil(choice) <-
           Enum.find(current["choices"], &(&1["id"] == choice_id)),
         true <- eligible?(choice, state.flags, state.clocks),
         {:ok, key, critical} <- outcome(choice, dice) do
      result = choice["outcomes"][key]
      effects = result["effects"] ++ if(critical, do: choice["critical_effects"], else: [])
      next = node(definition, result["next_node"])
      updated = Enum.reduce(effects, state, &apply_effect/2)

      if Flags.valid?(updated.flags) do
        {:ok,
         %{
           updated
           | node_id: next["id"],
             status: if(next["ending"], do: :completed, else: :active)
         }, %{outcome: key, critical: critical, text: result["text"], effects: effects}}
      else
        {:error, :invalid_flags}
      end
    else
      _ -> {:error, :invalid_transition}
    end
  end

  defp valid_state?(definition, %{node_id: id, status: status, flags: flags, clocks: clocks})
       when is_map(clocks),
       do:
         Definition.id?(id) and status in [:active, :completed, :ended] and
           Flags.valid?(flags) and Definition.valid?(definition, clocks)

  defp valid_state?(_, _), do: false

  defp outcome(%{"mode" => "fixed"}, []), do: {:ok, "fixed", false}

  defp outcome(%{"mode" => "rolled", "dice" => count}, dice) when is_list(dice) do
    if length(dice) == count and Enum.all?(dice, &(is_integer(&1) and &1 in 1..6)) do
      key =
        cond do
          Enum.max(dice) == 6 -> "success"
          Enum.max(dice) >= 4 -> "partial"
          true -> "failure"
        end

      {:ok, key, Enum.count(dice, &(&1 == 6)) >= 2}
    else
      :error
    end
  end

  defp outcome(_, _), do: :error

  defp apply_effect(%{"type" => "set_flag", "key" => key, "flag" => flag}, state),
    do: %{state | flags: Map.put(state.flags, key, flag)}

  defp apply_effect(%{"type" => "clear_flag", "key" => key}, state),
    do: %{state | flags: Map.delete(state.flags, key)}

  defp apply_effect(%{"type" => "clock_delta", "clock_id" => id, "delta" => delta}, state) do
    %{state | clocks: Map.update!(state.clocks, id, &AsyncWorlds.Clocks.Rules.adjust(&1, delta))}
  end

  def project(definition, state) do
    current = node(definition, state.node_id)

    choices =
      if state.status == :active do
        Enum.flat_map(current["choices"], fn choice ->
          eligible = eligible?(choice, state.flags, state.clocks)

          cond do
            not eligible and choice["eligibility"] == "hidden" ->
              []

            eligible ->
              [%{id: choice["id"], label: choice["label"], enabled: true}]

            true ->
              [
                %{
                  id: choice["id"],
                  label: choice["label"],
                  enabled: false,
                  hint: "Not available right now."
                }
              ]
          end
        end)
      else
        []
      end

    %{text: current["text"], completed: state.status == :completed, choices: choices}
  end
end
