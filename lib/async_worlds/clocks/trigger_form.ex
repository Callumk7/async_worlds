defmodule AsyncWorlds.Clocks.TriggerForm do
  @moduledoc "Browser-only projection of typed trigger inputs; domain validation stays authoritative."
  alias AsyncWorlds.Quests.EffectAuthoring

  @payload ~w(text clock_id character_id quest_id key flag)

  def params(params, previous, changed_type \\ nil) do
    Map.update(params, "triggers", [], fn triggers ->
      normalize(triggers, previous, changed_type)
    end)
  end

  defp normalize(triggers, previous, changed_type) when is_map(triggers) or is_list(triggers) do
    entries =
      if is_map(triggers),
        do: Map.to_list(triggers),
        else: Enum.with_index(triggers, fn t, i -> {to_string(i), t} end)

    Map.new(entries, fn
      {index, trigger} when is_map(trigger) ->
        old =
          case EffectAuthoring.integer(index) do
            i when is_integer(i) and i >= 0 -> Enum.at(previous, i)
            _ -> nil
          end

        trigger = if index == changed_type, do: clear_unused(trigger), else: trigger
        trigger = Enum.reduce(@payload, trigger, &Map.put_new(&2, &1, nil))
        {index, Map.update!(trigger, "flag", &flag(&1, old))}

      entry ->
        entry
    end)
  end

  defp normalize(triggers, _, _), do: triggers

  defp clear_unused(trigger) do
    used =
      case trigger["type"] do
        "set_flag" -> ~w(character_id key flag)
        "unlock_quest" -> ~w(character_id quest_id)
        "start_clock" -> ~w(clock_id)
        _ -> ~w(text)
      end

    Enum.reduce(@payload -- used, trigger, &Map.put(&2, &1, nil))
  end

  defp flag(%{"type" => type, "value" => value, "player_visible" => visible} = flag, old)
       when is_binary(type) and is_binary(value) and is_binary(visible) do
    effect = EffectAuthoring.new("set_flag")

    effect =
      if old && old.flag && EffectAuthoring.editable?(%{effect | "flag" => old.flag}),
        do: %{effect | "flag" => old.flag},
        else: effect

    converted =
      EffectAuthoring.apply_form(
        effect,
        %{"f_flag_type" => type, "f_value" => value, "f_visible" => visible},
        "f"
      )

    Map.merge(flag, converted["flag"])
  end

  defp flag(flag, _), do: flag
end
