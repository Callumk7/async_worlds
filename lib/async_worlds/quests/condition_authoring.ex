defmodule AsyncWorlds.Quests.ConditionAuthoring do
  @moduledoc "Character flag equality form vocabulary. Other imported conditions remain opaque."
  alias AsyncWorlds.Quests.EffectAuthoring

  def new,
    do: %{"type" => "character_flag", "key" => "", "flag_type" => "boolean", "value" => true}

  def editable?(%{"type" => "character_flag"} = condition) do
    AsyncWorlds.Quests.Definition.keys?(condition, ~w(type key flag_type value)) and
      EffectAuthoring.editable?(effect(condition))
  end

  def editable?(_), do: false

  def effect(condition) do
    %{
      "type" => "set_flag",
      "key" => condition["key"],
      "flag" => %{
        "type" => condition["flag_type"],
        "value" => condition["value"],
        "player_visible" => false
      }
    }
  end

  def form_params(condition) do
    if editable?(condition),
      do: EffectAuthoring.form_params(effect(condition)) |> Map.delete("visible"),
      else: %{}
  end

  def apply_form(condition, params, prefix) do
    if editable?(condition) do
      updated = EffectAuthoring.apply_form(effect(condition), params, prefix)

      %{
        condition
        | "key" => updated["key"],
          "flag_type" => updated["flag"]["type"],
          "value" => updated["flag"]["value"]
      }
    else
      condition
    end
  end

  def safe_edit?(old, new),
    do:
      is_list(new) and length(new) <= 100 and
        Enum.reject(old, &editable?/1) == Enum.reject(new, &editable?/1)

  def restructure(items, "add", _), do: if(length(items) < 100, do: items ++ [new()], else: items)

  def restructure(items, action, index) when is_integer(index) and index >= 0 do
    case Enum.at(items, index) do
      nil -> items
      item -> if editable?(item), do: reorder(items, action, index, item), else: items
    end
  end

  def restructure(items, _, _), do: items
  defp reorder(items, "remove", index, _), do: List.delete_at(items, index)

  defp reorder(items, action, index, item) when action in ~w(up down) do
    target = index + if(action == "up", do: -1, else: 1)

    if target >= 0 and target < length(items),
      do: items |> List.delete_at(index) |> List.insert_at(target, item),
      else: items
  end

  defp reorder(items, _, _, _), do: items
end
