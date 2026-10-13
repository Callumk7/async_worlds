defmodule AsyncWorlds.Quests.EffectAuthoring do
  @moduledoc "Minimal typed effect form vocabulary; unknown effect fields stay opaque."

  def new("clock_delta"), do: %{"type" => "clock_delta", "clock_id" => 0, "delta" => 1}
  def new("clear_flag"), do: %{"type" => "clear_flag", "key" => ""}

  def new("set_flag"),
    do: %{
      "type" => "set_flag",
      "key" => "",
      "flag" => %{"type" => "boolean", "value" => true, "player_visible" => false}
    }

  def editable?(%{"type" => type} = effect) when type in ~w(clock_delta clear_flag set_flag) do
    Enum.sort(Map.keys(effect)) == Enum.sort(Map.keys(new(type))) and
      projectable_fields?(effect)
  end

  def editable?(_), do: false

  defp projectable_fields?(%{"type" => "clock_delta"} = effect),
    do: scalar?(effect["clock_id"]) and scalar?(effect["delta"])

  defp projectable_fields?(%{"type" => "clear_flag"} = effect), do: is_binary(effect["key"])

  defp projectable_fields?(%{"type" => "set_flag"} = effect) do
    is_binary(effect["key"]) and
      AsyncWorlds.Quests.Definition.keys?(effect["flag"], ~w(type value player_visible)) and
      effect["flag"]["type"] in ~w(boolean integer string) and
      Enum.all?(Map.values(effect["flag"]), &scalar?/1)
  end

  defp scalar?(value), do: is_binary(value) or is_integer(value) or is_boolean(value)

  def safe_edit?(old, new) do
    is_list(new) and length(new) <= 100 and
      Enum.reject(old, &editable?/1) == Enum.reject(new, &editable?/1)
  end

  def form_params(effect) do
    if editable?(effect), do: params(effect), else: %{}
  end

  defp params(effect) do
    case effect["type"] do
      "clock_delta" ->
        Map.take(effect, ~w(clock_id delta)) |> Map.new(fn {k, v} -> {k, to_string(v)} end)

      "clear_flag" ->
        %{"key" => effect["key"]}

      "set_flag" ->
        %{
          "key" => effect["key"],
          "flag_type" => effect["flag"]["type"],
          "value" => to_string(effect["flag"]["value"]),
          "visible" => to_string(effect["flag"]["player_visible"])
        }

      _ ->
        %{}
    end
  end

  def apply_form(effect, params, prefix) do
    if editable?(effect) do
      values =
        Map.new(params(effect), fn {key, default} ->
          value = Map.get(params, prefix <> "_" <> key, default)
          {key, if(is_binary(value), do: value, else: default)}
        end)

      case effect["type"] do
        "clock_delta" ->
          %{
            effect
            | "clock_id" => integer(values["clock_id"]),
              "delta" => integer(values["delta"])
          }

        "clear_flag" ->
          %{effect | "key" => values["key"]}

        "set_flag" ->
          value =
            case values["flag_type"] do
              "integer" -> integer(values["value"])
              "boolean" -> boolean(values["value"])
              "string" -> preserve_string(effect["flag"], values["value"])
              _ -> values["value"]
            end

          %{
            effect
            | "key" => values["key"],
              "flag" => %{
                "type" => values["flag_type"],
                "value" => value,
                "player_visible" => boolean(values["visible"])
              }
          }
      end
    else
      effect
    end
  end

  defp preserve_string(%{"type" => "string", "value" => old}, submitted)
       when is_binary(old) do
    normalized = old |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
    if submitted == normalized, do: old, else: submitted
  end

  defp preserve_string(_, submitted), do: submitted

  @doc "Local ordered bonus operations; opaque imported items cannot be removed."
  def restructure(effects, type, _) when type in ~w(clock_delta set_flag clear_flag) do
    if length(effects) < 100, do: effects ++ [new(type)], else: effects
  end

  def restructure(effects, action, index) when is_integer(index) and index >= 0 do
    case Enum.at(effects, index) do
      nil ->
        effects

      effect ->
        if editable?(effect), do: move_or_remove(effects, action, index, effect), else: effects
    end
  end

  def restructure(effects, _, _), do: effects
  defp move_or_remove(effects, "remove", index, _), do: List.delete_at(effects, index)

  defp move_or_remove(effects, action, index, effect) when action in ~w(up down) do
    target = index + if(action == "up", do: -1, else: 1)

    if target >= 0 and target < length(effects),
      do: effects |> List.delete_at(index) |> List.insert_at(target, effect),
      else: effects
  end

  defp move_or_remove(effects, _, _, _), do: effects

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  def integer(value), do: value
  defp boolean("true"), do: true
  defp boolean("false"), do: false
  defp boolean(value), do: value
end
