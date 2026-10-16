defmodule AsyncWorlds.LinkHistoryTest do
  use AsyncWorlds.DataCase, async: true

  alias AsyncWorlds.{Campaigns, Characters, Factions, LinkHistory, Locations, Ticks}
  alias AsyncWorlds.LinkHistory.Change
  alias AsyncWorlds.Ticks.{Snapshot, Tick, WorldResolver}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    scope = %{campaign: campaign, discord_user_id: campaign.dm_user_id}
    {:ok, character} = Characters.create_character(campaign, campaign.dm_user_id, %{name: "Mira"})
    {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})

    # Test-only current-state table proves atomic integration without introducing
    # the actual membership feature (ENG-83) in this foundation issue.
    Repo.query!("CREATE TEMP TABLE history_test_links (id bigserial PRIMARY KEY, role text)")

    %{
      scope: scope,
      other: %{campaign: other, discord_user_id: other.dm_user_id},
      character: character,
      faction: faction
    }
  end

  test "setup changes belong to tick 1 without opening a tick or delivering anything", c do
    character = Repo.get!(Characters.Character, c.character.id)
    jobs = Repo.aggregate(Oban.Job, :count)
    deliveries = Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count)
    assert {:ok, id} = join(c)
    assert {:ok, %{items: [record]}} = LinkHistory.list_changes(c.scope)
    assert record.tick_number == 1
    assert record.link_id == id
    assert record.kind == :faction_membership
    assert record.entity_refs == refs(c)
    assert record.before == nil
    assert record.after == state(c, "Scout")
    assert record.actor_id == c.scope.discord_user_id
    assert record.inserted_at
    assert Ticks.active_tick(c.scope.campaign.id) == nil
    assert Repo.get!(Characters.Character, c.character.id) == character
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == deliveries
  end

  test "opening a future tick preserves earlier association and subsequent changes share it", c do
    assert {:ok, _} = join(c)
    assert {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    assert {:ok, _} = join(c, "Captain")

    assert {:ok, %{items: [first, second]}} =
             LinkHistory.list_changes(c.scope, tick_number: tick.number)

    assert first.tick_number == tick.number
    assert second.tick_number == tick.number
    assert first.id < second.id
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope, tick_number: 2)
  end

  test "resolving and in-review changes belong to the next tick and never rewrite snapshots", c do
    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)
    assert {:ok, _} = join(c)
    {:ok, payload} = WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(c.scope.campaign.id, tick.id, snapshot.revision, payload)

    assert {:ok, _} = join(c, "Captain")
    assert Repo.get!(Snapshot, snapshot.id) == snapshot
    assert {:ok, %{items: records}} = LinkHistory.list_changes(c.scope, tick_number: 2)
    assert length(records) == 2
    assert Enum.all?(records, &(&1.tick_number == tick.number + 1))

    {:ok, _} = Ticks.publish_tick(c.scope.campaign.id, tick.id, draft.id)
    assert {:ok, _} = join(c, "Leader")
    {:ok, next} = Ticks.open_tick(c.scope.campaign.id)
    assert next.number == 2
    assert {:ok, %{items: all}} = LinkHistory.list_changes(c.scope, tick_number: next.number)
    assert length(all) == 3
    assert Enum.take(all, 2) == records
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope, tick_number: tick.number)
  end

  test "retained join and leave survive removal of current link and entity", c do
    {:ok, id} = join(c)

    assert {:ok, :left} =
             LinkHistory.transact(c.scope, fn _campaign ->
               Repo.query!("DELETE FROM history_test_links WHERE id = $1", [id])
               {:ok, :left, [descriptor(c, state(c, "Scout"), nil, id)]}
             end)

    assert Repo.query!("SELECT * FROM history_test_links").rows == []
    Repo.delete!(c.faction)

    assert {:ok, %{items: [joined, left]}} =
             LinkHistory.list_changes(c.scope, entity: {"faction", c.faction.id})

    assert joined.link_id == left.link_id
    assert left.before == joined.after
    assert left.after == nil

    assert {:ok, %{items: [^joined, ^left]}} =
             LinkHistory.list_changes(c.scope, entity: {"character", c.character.id})
  end

  test "containment retains old and new parents for querying either entity", c do
    locations =
      for name <- ["Harbour", "City", "Region"] do
        {:ok, location} = Locations.create_location(c.scope, %{name: name})
        location
      end

    [child, old, new] = locations

    attrs = %{
      kind: :location_containment,
      entity_refs: %{"location" => Enum.map(locations, & &1.id)},
      before: %{"location_id" => child.id, "parent_id" => old.id},
      after: %{"location_id" => child.id, "parent_id" => new.id}
    }

    assert {:ok, :reparented} =
             LinkHistory.transact(c.scope, fn _ -> {:ok, :reparented, [attrs]} end)

    for location <- locations do
      assert {:ok, %{items: [record]}} =
               LinkHistory.list_changes(c.scope, entity: {"location", location.id})

      assert record.before == attrs.before
      assert record.after == attrs.after
    end
  end

  test "callback failures roll back current writes", c do
    assert {:error, :invalid_role} =
             LinkHistory.transact(c.scope, fn _ ->
               Repo.query!("INSERT INTO history_test_links(role) VALUES ('Scout')")
               {:error, :invalid_role}
             end)

    assert Repo.query!("SELECT * FROM history_test_links").rows == []
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "callback exceptions roll back current writes and propagate", c do
    assert_raise RuntimeError, "write failed", fn ->
      LinkHistory.transact(c.scope, fn _ ->
        Repo.query!("INSERT INTO history_test_links(role) VALUES ('Scout')")
        raise "write failed"
      end)
    end

    assert Repo.query!("SELECT * FROM history_test_links").rows == []
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "invalid history rolls back earlier history inserts and current writes in a batch", c do
    {:ok, foreign} = Factions.create_faction(c.other, %{name: "Foreign"})

    bad = %{
      descriptor(c, nil, state(c, "Scout"))
      | entity_refs: %{"character" => [c.character.id], "faction" => [foreign.id]}
    }

    assert {:error, :not_found} =
             LinkHistory.transact(c.scope, fn _ ->
               Repo.query!("INSERT INTO history_test_links(role) VALUES ('Scout')")
               {:ok, :value, [descriptor(c, nil, state(c, "Scout")), bad]}
             end)

    assert Repo.query!("SELECT * FROM history_test_links").rows == []
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "no-op states and empty change lists produce no history", c do
    same = state(c, "Scout")

    assert {:ok, :unchanged} =
             LinkHistory.transact(c.scope, fn _ ->
               {:ok, :unchanged, [descriptor(c, same, same)]}
             end)

    assert {:ok, :unchanged} = LinkHistory.transact(c.scope, fn _ -> {:ok, :unchanged, []} end)
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "malformed descriptors and callbacks fail atomically", c do
    for changes <- [
          [%{kind: :unknown}],
          [Map.drop(descriptor(c, nil, state(c, "Scout")), [:after])],
          [:bad],
          List.duplicate(%{}, 101)
        ] do
      assert {:error, _} =
               LinkHistory.transact(c.scope, fn _ ->
                 Repo.query!("INSERT INTO history_test_links(role) VALUES ('Scout')")
                 {:ok, :bad, changes}
               end)

      assert Repo.query!("SELECT * FROM history_test_links").rows == []
    end

    assert {:error, :invalid_changes} = LinkHistory.transact(c.scope, fn _ -> :bad end)
    assert {:error, :invalid_operation} = LinkHistory.transact(c.scope, :bad)
  end

  test "caller cannot choose campaign, actor, tick, ID or timestamps", c do
    attrs =
      descriptor(c, nil, state(c, "Scout"))
      |> Map.merge(%{
        campaign_id: c.other.campaign.id,
        tick_number: 999,
        actor_id: "999",
        id: -1,
        inserted_at: ~U[2000-01-01 00:00:00Z]
      })

    assert {:ok, :ok} = LinkHistory.transact(c.scope, fn _ -> {:ok, :ok, [attrs]} end)
    assert {:ok, %{items: [record]}} = LinkHistory.list_changes(c.scope)
    assert record.campaign_id == c.scope.campaign.id
    assert record.tick_number == 1
    assert record.actor_id == c.scope.discord_user_id
    assert record.id > 0
    assert record.inserted_at.year != 2000
  end

  test "fresh DM authorization protects writes and reads before callback execution", c do
    denied = %{c.scope | discord_user_id: "999"}

    for scope <- [denied, %{}, %{c.scope | discord_user_id: "bad"}] do
      assert {:error, _} =
               LinkHistory.transact(scope, fn _ -> flunk("unauthorized callback ran") end)

      assert {:error, _} = LinkHistory.list_changes(scope)
    end

    Repo.update!(change(c.scope.campaign, public_channel_id: "791"))

    assert {:error, :stale_campaign} =
             LinkHistory.transact(c.scope, fn _ -> flunk("stale callback ran") end)

    assert {:error, :stale_campaign} = LinkHistory.list_changes(c.scope)
  end

  test "DM revocation is refreshed", c do
    Repo.update!(change(c.scope.campaign, dm_user_id: "999"))
    assert {:error, :unauthorized} = join(c)
    assert {:error, :unauthorized} = LinkHistory.list_changes(c.scope)
  end

  test "history is campaign scoped and supports bounded stable entity/tick pagination", c do
    for role <- ["First", "Second", "Third"], do: assert({:ok, _} = join(c, role))

    assert {:ok, %{items: [first], more?: true, next_cursor: cursor}} =
             LinkHistory.list_changes(c.scope,
               limit: 1,
               entity: {"character", to_string(c.character.id)},
               tick_number: "1"
             )

    assert cursor == first.id

    assert {:ok, %{items: [second, third], more?: false, next_cursor: nil}} =
             LinkHistory.list_changes(c.scope, after_id: cursor, limit: 2)

    assert first.id < second.id and second.id < third.id

    assert {:ok, %{items: []}} =
             LinkHistory.list_changes(c.other, entity: {"character", c.character.id})

    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope, entity: {"faction", 9_999_999})
  end

  test "malformed and overflowing query filters fail closed", c do
    for opts <- [
          %{},
          [unknown: true],
          [tick_number: 0],
          [tick_number: 2_147_483_648],
          [entity: {"user", 1}],
          [entity: {"character", -1}],
          [entity: {"location", 9_223_372_036_854_775_808}],
          [limit: 101],
          [limit: nil],
          [after_id: -1],
          [after_id: "bad"]
        ] do
      assert {:error, :invalid_filters} = LinkHistory.list_changes(c.scope, opts)
    end
  end

  test "database prevents historical updates/deletes but permits campaign teardown", c do
    {:ok, _} = join(c)
    {:ok, %{items: [record]}} = LinkHistory.list_changes(c.scope)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(change(record, tick_number: 2), mode: :savepoint)
    end

    assert_raise Postgrex.Error, ~r/immutable/, fn -> Repo.delete!(record, mode: :savepoint) end
    assert Repo.get!(Change, record.id) == record
    Repo.delete!(c.scope.campaign)
    refute Repo.get(Change, record.id)
  end

  test "tick number exhaustion fails before current-state callback", c do
    Repo.update!(change(c.scope.campaign, current_tick_number: 2_147_483_647))

    assert {:error, :tick_number_exhausted} =
             LinkHistory.transact(c.scope, fn _ -> flunk("callback ran") end)

    assert Repo.aggregate(Tick, :count) == 0
  end

  defp join(c, role \\ "Scout") do
    LinkHistory.transact(c.scope, fn campaign ->
      assert campaign.id == c.scope.campaign.id

      %{rows: [[id]]} =
        Repo.query!("INSERT INTO history_test_links(role) VALUES ($1) RETURNING id", [role])

      {:ok, id, [descriptor(c, nil, state(c, role), id)]}
    end)
  end

  defp descriptor(c, before, after_state, link_id \\ nil),
    do: %{
      kind: :faction_membership,
      link_id: link_id,
      entity_refs: refs(c),
      before: before,
      after: after_state
    }

  defp refs(c), do: %{"character" => [c.character.id], "faction" => [c.faction.id]}

  defp state(c, role),
    do: %{"character_id" => c.character.id, "faction_id" => c.faction.id, "role" => role}
end
