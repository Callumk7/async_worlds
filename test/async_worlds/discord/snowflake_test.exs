defmodule AsyncWorlds.Discord.SnowflakeTest do
  use ExUnit.Case, async: true

  alias AsyncWorlds.Discord.Snowflake

  test "casting, loading and dumping preserve the full unsigned range" do
    for value <- [1, "1", 9_007_199_254_740_993, "18446744073709551615"] do
      expected = to_string(value)
      assert {:ok, ^expected} = Snowflake.cast(value)
      assert {:ok, ^expected} = Snowflake.dump(value)
      assert {:ok, ^expected} = Snowflake.load(expected)
    end
  end

  test "invalid and noncanonical identifiers are rejected" do
    for value <- [
          nil,
          false,
          0,
          -1,
          1.0,
          "",
          "0",
          "01",
          "+1",
          "-1",
          "1\n",
          " 1",
          "1 ",
          "1e3",
          "18446744073709551616",
          18_446_744_073_709_551_616,
          String.duplicate("1", 100),
          %{},
          []
        ] do
      assert :error = Snowflake.cast(value)
      assert :error = Snowflake.dump(value)
      assert :error = Snowflake.load(value)
    end
  end
end
