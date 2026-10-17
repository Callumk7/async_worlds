defmodule AsyncWorlds.ScopedID do
  @moduledoc false
  def cast(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  def cast(id) when is_binary(id) and byte_size(id) <= 19 do
    case Integer.parse(id) do
      {number, ""} -> cast(number)
      _ -> {:error, :not_found}
    end
  end

  def cast(_), do: {:error, :not_found}
end
