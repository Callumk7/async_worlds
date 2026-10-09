defmodule AsyncWorlds.Discord.Snowflake do
  @moduledoc """
  Validates Discord's unsigned 64-bit identifiers without loss of precision.

  Accepts positive integers or canonical decimal strings and stores strings.
  Floats, whitespace, signs, leading zeroes and values outside uint64 are rejected.
  """
  use Ecto.Type

  @max 18_446_744_073_709_551_615

  def type, do: :string

  def cast(value) when is_integer(value) and value > 0 and value <= @max,
    do: {:ok, Integer.to_string(value)}

  def cast(value) when is_binary(value) and byte_size(value) in 1..20 do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
      case Integer.parse(value) do
        {number, ""} when number <= @max -> {:ok, value}
        _ -> :error
      end
    else
      :error
    end
  end

  def cast(_), do: :error
  def load(value), do: cast(value)
  def dump(value), do: cast(value)
end
