defmodule AsyncWorlds.Ticks.SynthesisTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Ticks.Synthesis

  defp data do
    %{
      "tensions" => [%{"id" => 1}, %{"id" => 2}],
      "tension_commitments" => [
        %{
          "character_id" => 10,
          "commitments" => [
            %{
              "character_id" => 10,
              "tension_id" => 1,
              "version" => 2,
              "state" => "confirmed",
              "approach" => "Ash Company"
            },
            %{
              "character_id" => 10,
              "tension_id" => 2,
              "version" => 1,
              "state" => "unresolved",
              "approach" => "Ash Company"
            }
          ]
        },
        %{
          "character_id" => 11,
          "commitments" => [
            %{"character_id" => 11, "tension_id" => 1, "version" => 0, "state" => "absent"}
          ]
        }
      ]
    }
  end

  test "frozen anchors and cross-Tension contributions are inspectable independent of roster order" do
    d = data()
    rows = Synthesis.entries(d)
    assert Enum.map(rows, & &1.anchor) == ["intent-1-10-v2", "intent-1-11-v0", "intent-2-10-v1"]
    assert length(hd(rows).elsewhere) == 1
    assert rows == Synthesis.entries(Map.update!(d, "tension_commitments", &Enum.reverse/1))
  end

  test "interpretation and deliberate deferral validate only frozen attribution, never execute intent" do
    op = %{
      "type" => "synthesis",
      "tension_id" => 1,
      "interpretation" => "Company cannot be in both places",
      "deferred" => [11]
    }

    review = Synthesis.apply_operation(%{}, op)
    assert :ok = Synthesis.validate!(data(), review)
    assert get_in(review, ["synthesis", "1", "deferred"]) == [11]

    assert_raise ArgumentError, fn ->
      Synthesis.validate!(data(), Synthesis.apply_operation(%{}, Map.put(op, "deferred", [999])))
    end

    assert_raise ArgumentError, fn ->
      Synthesis.validate!(data(), Synthesis.apply_operation(%{}, Map.put(op, "tension_id", 99)))
    end

    assert_raise ArgumentError, fn -> Synthesis.validate!(%{}, review) end

    for bad <- [nil, <<255>>, "NUL" <> <<0>>, String.duplicate("x", 8001)] do
      assert_raise ArgumentError, fn ->
        Synthesis.validate!(
          data(),
          Synthesis.apply_operation(%{}, Map.put(op, "interpretation", bad))
        )
      end
    end

    for bad <- [[11, 11], ["11"], %{}, nil] do
      assert_raise ArgumentError, fn ->
        Synthesis.validate!(data(), Synthesis.apply_operation(%{}, Map.put(op, "deferred", bad)))
      end
    end

    assert :ok = Synthesis.validate!(%{}, %{})
  end
end
