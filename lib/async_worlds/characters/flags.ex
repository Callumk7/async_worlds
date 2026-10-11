defmodule AsyncWorlds.Characters.Flags do
  @moduledoc "Strict JSON flag facts: boolean, integer or string, with explicit player visibility."

  def valid?(flags) when is_map(flags) and map_size(flags) <= 100 do
    Enum.all?(flags, fn {key, flag} -> valid_key?(key) and valid_flag?(flag) end)
  end

  def valid?(_), do: false

  def valid_key?(key) when is_binary(key),
    do: byte_size(key) <= 64 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, key)

  def valid_key?(_), do: false

  def valid_flag?(%{"type" => type, "value" => value, "player_visible" => visible} = flag)
      when map_size(flag) == 3 and is_boolean(visible) do
    case type do
      "boolean" ->
        is_boolean(value)

      "integer" ->
        is_integer(value) and value in -9_007_199_254_740_991..9_007_199_254_740_991

      "string" ->
        is_binary(value) and String.valid?(value) and byte_size(value) <= 2000 and
          not String.contains?(value, <<0>>)

      _ ->
        false
    end
  end

  def valid_flag?(_), do: false
end
