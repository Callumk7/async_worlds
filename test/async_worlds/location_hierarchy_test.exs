defmodule AsyncWorlds.LocationHierarchyTest do
  # The rollback test installs a transaction-local trigger on the history table.
  use AsyncWorlds.DataCase, async: false

  alias AsyncWorlds.{Campaigns, LinkHistory, Locations, Repo, Ticks}
  alias AsyncWorlds.Locations.Location
  alias AsyncWorlds.Ticks.{Snapshot, WorldResolver}

  setup do
    scopes =
      for {guild, dm} <- [{"123", "456"}, {"124", "457"}] do
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild,
            dm_user_id: dm,
            public_channel_id: "789"
          })

        %{campaign: campaign, discord_user_id: dm}
      end

    [scope, other] = scopes
    %{scope: scope, other: other}
  end

  test "metadata preserves existing identity and parent writes are explicit", %{scope: scope} do
    root = location(scope, "Region")
    child = location(scope, "City")
    assert child.parent_id == nil
    assert child.kind == nil

    assert {:ok, updated} =
             Locations.update_location(scope, child.id, %{
               kind: "a wholly custom kind",
               parent_id: root.id,
               campaign_id: -1
             })

    assert updated.id == child.id
    assert updated.description == child.description
    assert updated.campaign_id == child.campaign_id
    assert updated.parent_id == nil
    assert updated.kind == "a wholly custom kind"
    assert {:ok, cleared} = Locations.update_location(scope, child.id, %{kind: " "})
    assert cleared.kind == nil

    assert {:error, %Ecto.Changeset{}} =
             Locations.update_location(scope, child.id, %{kind: "bad" <> <<0>>})

    assert {:ok, %{items: []}} = LinkHistory.list_changes(scope)
  end

  test "set, no-op, reparent and clear retain endpoint states in stable order", %{scope: scope} do
    old = location(scope, "Region")
    new = location(scope, "Other region")
    child = location(scope, "City")
    assert {:ok, linked} = Locations.set_parent(scope, to_string(child.id), to_string(old.id))
    assert linked.parent_id == old.id
    assert {:ok, ^linked} = Locations.set_parent(scope, child.id, old.id)
    assert {:ok, reparented} = Locations.set_parent(scope, child.id, new.id)
    assert reparented.parent_id == new.id
    assert {:ok, cleared} = Locations.clear_parent(scope, child.id)
    assert cleared.parent_id == nil
    assert {:ok, ^cleared} = Locations.clear_parent(scope, child.id)

    assert {:ok, %{items: [set, reparent, clear]}} = LinkHistory.list_changes(scope)
    assert set.id < reparent.id and reparent.id < clear.id
    assert set.before == nil
    assert set.after == %{"location_id" => child.id, "parent_id" => old.id}
    assert reparent.before == set.after
    assert reparent.after == %{"location_id" => child.id, "parent_id" => new.id}
    assert clear.before == reparent.after
    assert clear.after == nil
    assert Enum.all?([set, reparent, clear], &(&1.tick_number == 1))
    assert reparent.kind == :location_containment
    assert reparent.actor_id == scope.discord_user_id
    assert MapSet.new(reparent.entity_refs["location"]) == MapSet.new([child.id, old.id, new.id])

    for parent <- [old, new] do
      assert {:ok, %{items: items}} =
               LinkHistory.list_changes(scope, entity: {"location", parent.id})

      assert Enum.any?(items, &(&1.id == reparent.id))
    end
  end

  test "cycles and invalid endpoints leave state and history untouched", c do
    root = location(c.scope, "Root")
    middle = location(c.scope, "Middle")
    leaf = location(c.scope, "Leaf")
    foreign = location(c.other, "Foreign")
    {:ok, _} = Locations.set_parent(c.scope, middle.id, root.id)
    {:ok, _} = Locations.set_parent(c.scope, leaf.id, middle.id)
    {:ok, before} = LinkHistory.list_changes(c.scope)

    for {child, parent} <- [{root.id, root.id}, {root.id, middle.id}, {root.id, leaf.id}] do
      assert {:error, :location_cycle} = Locations.set_parent(c.scope, child, parent)
    end

    for id <- [foreign.id, nil, "bad", %{}, 0, -1, 9_223_372_036_854_775_808] do
      assert {:error, :not_found} = Locations.set_parent(c.scope, id, root.id)
      assert {:error, :not_found} = Locations.breadcrumbs(c.scope, id)

      if id != nil do
        assert {:error, :not_found} = Locations.set_parent(c.scope, leaf.id, id)
        assert {:error, :not_found} = Locations.list_children(c.scope, id)
      end
    end

    assert {:ok, ^before} = LinkHistory.list_changes(c.scope)
    assert Repo.get!(Location, root.id).parent_id == nil
    assert Repo.get!(Location, leaf.id).parent_id == middle.id
  end

  test "children, roots and breadcrumbs are campaign-scoped and stable", c do
    root = location(c.scope, "Root")
    first = location(c.scope, "First")
    second = location(c.scope, "Second")
    leaf = location(c.scope, "Leaf")
    location(c.other, "Foreign")
    {:ok, first} = Locations.set_parent(c.scope, first.id, root.id)
    {:ok, second} = Locations.set_parent(c.scope, second.id, root.id)
    {:ok, leaf} = Locations.set_parent(c.scope, leaf.id, second.id)
    assert {:ok, [^root]} = Locations.list_children(c.scope)
    assert {:ok, [^first, ^second]} = Locations.list_children(c.scope, root.id)
    assert {:ok, []} = Locations.list_children(c.scope, leaf.id)
    assert {:ok, [^root, ^second, ^leaf]} = Locations.breadcrumbs(c.scope, leaf.id)
    assert {:ok, [^root]} = Locations.breadcrumbs(c.scope, root.id)

    assert {:ok, %{id: leaf.id, name: leaf.name, description: leaf.description}} ==
             Locations.get_campaign_location(c.scope.campaign.discord_guild_id, leaf.id)

    assert {:ok, summaries} = Locations.list_campaign_locations(c.scope.campaign.discord_guild_id)
    assert Enum.all?(summaries, &(Enum.sort(Map.keys(&1)) == [:id, :name]))
  end

  test "new operations freshly authorize before reads or writes", %{scope: scope} do
    root = location(scope, "Root")
    child = location(scope, "Child")

    operations = [
      &Locations.set_parent(&1, child.id, root.id),
      &Locations.clear_parent(&1, child.id),
      &Locations.list_children(&1, root.id),
      &Locations.breadcrumbs(&1, child.id)
    ]

    for operation <- operations do
      assert {:error, :unauthorized} = operation.(%{scope | discord_user_id: "999"})
      assert {:error, :invalid_scope} = operation.(%{})
      assert {:error, :invalid_id} = operation.(%{scope | discord_user_id: "bad"})
    end

    Repo.update!(change(scope.campaign, public_channel_id: "790"))
    for operation <- operations, do: assert({:error, :stale_campaign} = operation.(scope))
    Repo.update!(change(scope.campaign, dm_user_id: "999"))
    for operation <- operations, do: assert({:error, :unauthorized} = operation.(scope))
    assert Repo.get!(Location, child.id).parent_id == nil
  end

  test "database rejects foreign, missing and self parents even outside the context", c do
    child = location(c.scope, "Child")
    foreign = location(c.other, "Foreign")

    for parent_id <- [foreign.id, -1, child.id] do
      assert {:error, invalid} =
               Repo.update(Location.parent_changeset(child, parent_id), mode: :savepoint)

      assert invalid.errors[:parent_id]
    end

    assert Repo.get!(Location, child.id).parent_id == nil
  end

  test "deletion requires explicit link clearing and history survives both endpoints", %{
    scope: scope
  } do
    root = location(scope, "Root")
    child = location(scope, "Child")
    {:ok, _} = Locations.set_parent(scope, child.id, root.id)
    assert {:error, :location_linked} = Locations.delete_location(scope, root.id)
    assert {:error, :location_linked} = Locations.delete_location(scope, child.id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete(root, mode: :savepoint) end
    {:ok, _} = Locations.clear_parent(scope, child.id)
    assert {:ok, _} = Locations.delete_location(scope, root.id)
    assert {:ok, _} = Locations.delete_location(scope, child.id)

    assert {:ok, %{items: [_, _]}} =
             LinkHistory.list_changes(scope, entity: {"location", root.id})
  end

  test "whole-campaign deletion still cascades a linked hierarchy", %{scope: scope} do
    root = location(scope, "Root")
    child = location(scope, "Child")
    {:ok, _} = Locations.set_parent(scope, child.id, root.id)
    Repo.delete!(scope.campaign)
    refute Repo.get(Location, root.id)
    refute Repo.get(Location, child.id)
  end

  test "history insertion failure rolls back the parent mutation", %{scope: scope} do
    root = location(scope, "Root")
    child = location(scope, "Child")
    # A transaction-local database failure exercises the actual hierarchy writer.
    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_containment() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'history unavailable'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER reject_containment BEFORE INSERT ON link_changes
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_containment()
    """)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> Locations.set_parent(scope, child.id, root.id) end, mode: :savepoint)
    end

    assert Repo.get!(Location, child.id).parent_id == nil
    assert {:ok, %{items: []}} = LinkHistory.list_changes(scope)
  end

  test "traversal is bounded and detects pre-existing corruption", %{scope: scope} do
    root = location(scope, "Root")

    leaf =
      Enum.reduce(1..100, root, fn n, parent ->
        %Location{campaign_id: scope.campaign.id, parent_id: parent.id}
        |> Location.changeset(%{name: "Node #{n}"})
        |> Repo.insert!()
      end)

    assert {:error, :hierarchy_too_deep} = Locations.breadcrumbs(scope, leaf.id)
    assert {:error, :hierarchy_too_deep} = Locations.set_parent(scope, root.id, leaf.id)
    child = location(scope, "Child")
    Repo.update!(Location.parent_changeset(child, root.id))
    Repo.update!(Location.parent_changeset(root, child.id))
    assert {:error, :location_cycle} = Locations.breadcrumbs(scope, child.id)
  end

  test "descriptive edits leave character versions and gameplay state untouched", %{scope: scope} do
    {:ok, character} =
      AsyncWorlds.Characters.create_character(scope.campaign, scope.discord_user_id, %{
        name: "Mira"
      })

    character = Repo.get!(AsyncWorlds.Characters.Character, character.id)
    root = location(scope, "Root")
    child = location(scope, "Child")
    campaign = Repo.get!(AsyncWorlds.Campaigns.Campaign, scope.campaign.id)
    jobs = Repo.aggregate(Oban.Job, :count)
    deliveries = Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count)
    {:ok, _} = Locations.set_parent(scope, child.id, root.id)
    {:ok, _} = Locations.update_location(scope, child.id, %{kind: "City"})
    {:ok, _} = Locations.clear_parent(scope, child.id)
    assert Repo.get!(AsyncWorlds.Characters.Character, character.id) == character
    assert Repo.get!(AsyncWorlds.Campaigns.Campaign, campaign.id) == campaign
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == deliveries
  end

  test "attribution follows setup, open, resolving, review and next open tick", %{scope: scope} do
    root = location(scope, "Root")
    child = location(scope, "Child")
    jobs = Repo.aggregate(Oban.Job, :count)
    deliveries = Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count)
    {:ok, _} = Locations.set_parent(scope, child.id, root.id)
    assert Ticks.active_tick(scope.campaign.id) == nil
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == deliveries
    {:ok, tick} = Ticks.open_tick(scope.campaign.id)
    {:ok, _} = Locations.clear_parent(scope, child.id)
    {:ok, %{items: setup_records}} = LinkHistory.list_changes(scope, tick_number: 1)
    assert length(setup_records) == 2
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(scope.campaign.id, tick.id)
    {:ok, _} = Locations.set_parent(scope, child.id, root.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(scope.campaign.id, tick.id, snapshot.revision, payload)

    {:ok, _} = Locations.clear_parent(scope, child.id)
    assert Repo.get!(Snapshot, snapshot.id) == snapshot
    {:ok, %{items: future}} = LinkHistory.list_changes(scope, tick_number: 2)
    assert length(future) == 2
    {:ok, _} = Ticks.publish_tick(scope.campaign.id, tick.id, draft.id)
    {:ok, _} = Locations.set_parent(scope, child.id, root.id)
    {:ok, next} = Ticks.open_tick(scope.campaign.id)
    assert next.number == 2
    assert {:ok, %{items: records}} = LinkHistory.list_changes(scope, tick_number: next.number)
    assert Enum.take(records, 2) == future
    assert length(records) == 3
    assert {:ok, %{items: ^setup_records}} = LinkHistory.list_changes(scope, tick_number: 1)
  end

  defp location(scope, name) do
    {:ok, location} = Locations.create_location(scope, %{name: name, description: "Description"})
    location
  end
end
