defmodule AsyncWorlds.LinkHistory.ChangeTest do
  use ExUnit.Case, async: true

  alias AsyncWorlds.LinkHistory.Change

  test "validates typed endpoint references rather than arbitrary polymorphic identities" do
    valid = %{
      kind: :faction_membership,
      entity_refs: %{"character" => [1], "faction" => [2]},
      before: nil,
      after: %{"role" => "Scout"}
    }

    assert Change.changeset(%Change{}, valid).valid?

    for refs <- [
          %{},
          %{"character" => [1]},
          %{"character" => [1], "faction" => [2], "user" => [3]},
          %{"character" => [1, 2], "faction" => [2]},
          %{"character" => ["1"], "faction" => [2]},
          %{"character" => [0], "faction" => [2]},
          %{"character" => [9_223_372_036_854_775_808], "faction" => [2]}
        ] do
      refute Change.changeset(%Change{}, %{valid | entity_refs: refs}).valid?
    end
  end

  test "containment can identify child and both parents, with unique bounded identities" do
    attrs = %{
      kind: :location_containment,
      entity_refs: %{"location" => [1, 2, 3]},
      before: %{"parent_id" => 2},
      after: %{"parent_id" => 3}
    }

    assert Change.changeset(%Change{}, attrs).valid?

    for ids <- [[], [1, 1], [1, 2, 3, 4], [-1], [nil]] do
      refute Change.changeset(%Change{}, %{attrs | entity_refs: %{"location" => ids}}).valid?
    end
  end

  test "bounds snapshots and rejects unsafe or non-JSON values before PostgreSQL" do
    attrs = %{
      kind: :faction_membership,
      entity_refs: %{"character" => [1], "faction" => [2]},
      before: nil,
      after: %{"role" => "Scout"}
    }

    for state <- [
          %{"role" => "bad" <> <<0>>},
          %{"role" => <<255>>},
          %{role: "Scout"},
          %{"role" => :scout},
          %{"role" => self()},
          %{"role" => String.duplicate("x", 16_384)},
          Enum.reduce(1..10, %{}, fn _, acc -> %{"nested" => acc} end)
        ] do
      for field <- [:before, :after] do
        refute Change.changeset(%Change{}, Map.put(attrs, field, state)).valid?
      end
    end

    assert Change.changeset(%Change{}, %{
             attrs
             | after: %{"role" => nil, "nested" => [true, 1, %{"text" => "Captain"}]}
           }).valid?

    refute Change.changeset(%Change{}, Map.put(attrs, :link_id, -1)).valid?
    refute Change.changeset(%Change{}, Map.put(attrs, :kind, :unknown)).valid?
  end
end
