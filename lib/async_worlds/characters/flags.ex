defmodule AsyncWorlds.Characters.Flags do
  @moduledoc "Strict JSON flag facts: boolean, integer or string, with explicit player visibility."

  @doc "Parse ordinary form values, not JSON. Strings retain quotes and whitespace."
  def parse(params) when is_map(params) do
    with true <- valid_key?(params["key"]) || {:error, :invalid_flag_key},
         {:ok, value} <- parse_value(params["type"], params["value"]),
         visible when visible in ["true", "false"] <- params["player_visible"] do
      {:ok, %{"type" => params["type"], "value" => value, "player_visible" => visible == "true"}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_flag_visibility}
    end
  end

  def parse(_), do: {:error, :invalid_flag}

  defp parse_value("boolean", "true"), do: {:ok, true}
  defp parse_value("boolean", "false"), do: {:ok, false}

  defp parse_value("integer", value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number in -9_007_199_254_740_991..9_007_199_254_740_991 -> {:ok, number}
      _ -> {:error, :invalid_flag_integer}
    end
  end

  defp parse_value("string", value) when is_binary(value) do
    if valid_flag?(%{"type" => "string", "value" => value, "player_visible" => false}),
      do: {:ok, value},
      else: {:error, :invalid_flag_string}
  end

  defp parse_value(_, _), do: {:error, :invalid_flag_value}

  def valid?(flags) when is_map(flags) and map_size(flags) <= 100 do
    Enum.all?(flags, fn {key, flag} -> valid_key?(key) and valid_flag?(flag) end)
  end

  def valid?(_), do: false

  def valid_key?(key) when is_binary(key),
    do: String.valid?(key) and byte_size(key) <= 64 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, key)

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
