defmodule AsyncWorlds.TensionCommitmentsTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Repo, TensionCommitments, Tensions, Ticks}
  alias AsyncWorlds.Discord.{Commands, Dispatcher, FakeAdapter}

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, enabled: true, adapter: FakeAdapter)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    {:ok, c} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, player} = Characters.create_character(c, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, missing} =
      Characters.create_character(c, "456", %{name: "Absent", discord_user_id: "998"})

    {:ok, a} = Tensions.create_tension(c.id, %{name: "Battle", audience: :public}, "dm")
    {:ok, b} = Tensions.create_tension(c.id, %{name: "Harvest", audience: :public}, "dm")
    {:ok, private} = Tensions.create_tension(c.id, %{name: "PRIVATE TENSION"}, "dm")

    {:ok, clock} =
      Tensions.create_clock(
        c.id,
        a.id,
        %{name: "Public pressure", visibility: :public, segments: 8, background_rate: 1},
        "dm"
      )

    {:ok, _} =
      Tensions.create_clock(
        c.id,
        a.id,
        %{name: "Known pressure", visibility: :known, filled: 3, segments: 6},
        "dm"
      )

    {:ok, _} = Tensions.create_clock(c.id, a.id, %{name: "HIDDEN PRESSURE", segments: 8}, "dm")
    {:ok, tick} = Ticks.open_tick(c.id)

    %{
      c: c,
      player: player,
      missing: missing,
      a: a,
      b: b,
      private: private,
      tick: tick,
      clock: clock,
      scope: %{campaign: c, discord_user_id: "456"},
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp command(x, action, attrs, user \\ 999) do
    options =
      Enum.map(attrs, fn {key, value} ->
        %{name: key, type: if(is_integer(value), do: 4, else: 3), value: value}
      end)

    data = %{name: "intent", options: [%{name: action, type: 1, options: options}]}

    Dispatcher.handle(
      %{
        type: 2,
        id: System.unique_integer([:positive]),
        application_id: 111,
        guild_id: 123,
        member: %{user_id: user},
        token: "test-only",
        data: data
      },
      x.opts
    )
  end

  defp change(x, tension, version, op, attrs \\ %{}),
    do: TensionCommitments.change("123", "999", x.tick.id, tension.id, version, op, attrs)

  defp own(x) do
    {:ok, state} = TensionCommitments.player_state("123", "999", x.tick.id)
    hd(state.participation)
  end

  defp dm(x) do
    {:ok, state} = TensionCommitments.dm_state(x.scope, x.tick.id)
    state
  end

  test "Discord intention revisions preserve omitted approach but allow explicit replacement",
       x do
    assert {:ok, %{approach: nil}} = change(x, x.a, 0, :edit, %{"intention" => "First"})

    assert {:ok, %{version: 2}} =
             change(x, x.a, 1, :edit, %{
               "intention" => "First",
               "approach" => "Retained resources"
             })

    assert {:ok, %{version: 3}} = change(x, x.a, 2, :confirm)
    assert {:ok, %{version: 4, ready: true}} = change(x, x.a, 3, :ready)

    assert {:ok, _} =
             command(x, "edit", %{
               "tick" => x.tick.id,
               "tension" => x.a.id,
               "version" => 4,
               "intention" => "Revised"
             })

    assert [
             %{
               intention: "Revised",
               approach: "Retained resources",
               version: 5,
               state: :unresolved,
               ready: false
             }
           ] =
             Enum.filter(own(x).commitments, &(&1.tension_id == x.a.id))

    assert {:ok, %{approach: "New resources", version: 6}} =
             change(x, x.a, 5, :edit, %{"intention" => "Revised", "approach" => "New resources"})

    assert {:ok, %{approach: "", version: 7}} =
             change(x, x.a, 6, :edit, %{"intention" => "Revised", "approach" => ""})
  end

  test "documented quest-free Discord acceptance flow: two confirmations, revise, withdraw, retrieve, close",
       x do
    assert Repo.get_by(AsyncWorlds.Quests.Progression, character_id: x.player.id) == nil
    {:ok, view} = command(x, "view", %{"tick" => x.tick.id})
    assert view =~ "version 0"
    refute view =~ "PRIVATE TENSION"

    for tension <- [x.a, x.b] do
      assert {:ok, text} =
               command(x, "edit", %{
                 "tick" => x.tick.id,
                 "tension" => tension.id,
                 "version" => 0,
                 "intention" => "PRIVATE EFFORT #{tension.id}",
                 "approach" => "SECRET ASSETS @everyone"
               })

      assert text =~ "unresolved"

      assert {:ok, text} =
               command(x, "confirm", %{
                 "tick" => x.tick.id,
                 "tension" => tension.id,
                 "version" => 1
               })

      assert text =~ "confirmed"
      assert text =~ "not outcomes"
    end

    assert {:ok, %{ready: true, version: 3}} = change(x, x.a, 2, :ready)

    assert {:ok, %{state: :unresolved, ready: false, version: 4}} =
             change(x, x.a, 3, :edit, %{"intention" => "PRIVATE REVISED EFFORT"})

    assert {:error, :stale_commitment} = change(x, x.a, 2, :confirm)
    assert {:error, :stale_commitment} = change(x, x.a, 3, :ready)
    assert {:error, :invalid_commitment} = change(x, x.a, 4, :ready)
    assert {:ok, %{version: 5, ready: false}} = change(x, x.a, 4, :confirm)

    assert {:ok, %{state: :withdrawn, intention: nil, approach: nil}} =
             change(x, x.b, 2, :withdraw)

    assert Enum.find(dm(x).participation, &(&1.character_id == x.player.id)) == own(x)

    assert Enum.all?(
             Enum.find(dm(x).participation, &(&1.character_id == x.missing.id)).commitments,
             &(&1.state == :absent and not &1.ready)
           )

    {:ok, roster} = command(x, "roster", %{"tick" => x.tick.id}, 456)
    assert roster =~ "PRIVATE REVISED EFFORT"
    assert roster =~ "absent"
    assert {:error, :unauthorized} = command(x, "roster", %{"tick" => x.tick.id})

    # Outbox failures do not block retrieval; response failure must not undo or replay a write.
    delivery = Enum.find(Deliveries.list_deliveries(x.c.id), &(&1.kind == :public))
    FakeAdapter.fail(:send_public, {:error, {:permanent, :forbidden}})

    assert {:cancel, :forbidden} =
             AsyncWorlds.Workers.DeliverDiscord.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id, "generation" => delivery.generation}
             })

    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, delivery.id).status == :failed
    FakeAdapter.fail(:edit_response, {:error, :blocked})

    assert {:error, :response_failed} =
             command(x, "ready", %{"tick" => x.tick.id, "tension" => x.a.id, "version" => 5})

    FakeAdapter.fail(:edit_response, nil)
    {:ok, view} = command(x, "view", %{"tick" => x.tick.id})
    assert view =~ "version 6"
    assert view =~ "PRIVATE REVISED EFFORT"
    assert Repo.get!(AsyncWorlds.Clocks.Clock, x.clock.id).filled == 0
    assert Ticks.latest_published_tick(x.c.id) == nil
    assert Ticks.active_tick(x.c.id).status == :open

    for delivery <- Deliveries.list_deliveries(x.c.id) do
      refute delivery.content =~ "PRIVATE"
      refute delivery.content =~ "SECRET"
      refute delivery.content =~ "HIDDEN"
      refute delivery.content =~ "3/6"
    end

    before = dm(x).participation
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(x.c.id, x.tick.id)
    assert snapshot.data["tension_commitments"] == Jason.decode!(Jason.encode!(before))

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(
        Ecto.Changeset.change(snapshot,
          data: Map.put(snapshot.data, "tension_commitments", [])
        ),
        mode: :savepoint
      )
    end

    assert {:error, :tick_closed} = change(x, x.a, 6, :edit, %{"intention" => "late"})
    assert {:error, :tick_closed} = change(x, x.a, 6, :confirm)
    assert {:error, :tick_closed} = change(x, x.a, 6, :withdraw)
    assert Enum.find(dm(x).participation, &(&1.character_id == x.player.id)) == own(x)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    assert payload["events"] == []
    assert Enum.find(payload["clocks"], &(&1["id"] == x.clock.id))["filled"] == 1
    assert Repo.get!(AsyncWorlds.Clocks.Clock, x.clock.id).filled == 0
    refute Jason.encode!(payload) =~ "PRIVATE REVISED EFFORT"
    {:ok, %{draft: draft}} = Ticks.put_draft(x.c.id, x.tick.id, snapshot.revision, payload)
    assert {:ok, _} = Ticks.publish_tick(x.c.id, x.tick.id, draft.id)
    assert Repo.get!(AsyncWorlds.Clocks.Clock, x.clock.id).filled == 1

    for delivery <- Deliveries.list_deliveries(x.c.id), delivery.kind == :public do
      refute delivery.content =~ "PRIVATE"
      refute delivery.content =~ "SECRET"
      refute delivery.content =~ "HIDDEN"
      refute delivery.content =~ "3/6"
    end

    assert {:ok, ^snapshot} = Ticks.fetch_snapshot(x.c.id, x.tick.id)
  end

  test "absence and unresolved participation remain visible without requiring confirmation", x do
    {:ok, _} = change(x, x.a, 0, :edit, %{"intention" => "Still discussing"})
    assert [%{state: :unresolved, ready: false}, %{state: :absent}] = own(x).commitments
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(x.c.id, x.tick.id)

    assert Enum.any?(
             hd(snapshot.data["tension_commitments"])["commitments"],
             &(&1["state"] == "unresolved")
           )

    assert Enum.any?(snapshot.data["tension_commitments"], fn row ->
             Enum.all?(row["commitments"], &(&1["state"] == "absent"))
           end)
  end

  test "fresh ownership, campaign isolation, private tensions and DM revocation", x do
    assert {:error, :not_found} = change(x, x.private, 0, :edit, %{"intention" => "secret"})
    assert {:error, :not_found} = change(x, x.private, 0, :withdraw)

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Tensions.create_tension(other.id, %{name: "Foreign", audience: :public}, "dm")

    assert {:error, :not_found} = change(x, foreign, 0, :edit, %{"intention" => "x"})
    {:ok, tick} = Ticks.open_tick(other.id)
    assert {:error, :not_found} = TensionCommitments.player_state("123", "999", tick.id)
    {:ok, _} = change(x, x.a, 0, :edit, %{"intention" => "private owner text"})
    {:ok, _} = Characters.update_character(x.c, "456", x.player.id, %{discord_user_id: "997"})
    assert {:error, :not_found} = TensionCommitments.player_state("123", "999", x.tick.id)
    assert {:error, :not_found} = change(x, x.a, 1, :confirm)
    {:ok, stranger} = TensionCommitments.player_state("123", "998", x.tick.id)
    refute Jason.encode!(stranger) =~ "private owner text"

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = TensionCommitments.dm_state(x.scope, x.tick.id)
  end

  test "pre-ENG-93 v3 snapshots remain readable and publishable", x do
    # Capture the previous shape without changing the open fixture. No immutable
    # row is updated: the savepoint rollback removes the provisional close.
    {:error, provisional} =
      Repo.transaction(fn ->
        {:ok, %{snapshot: snapshot}} = Ticks.close_tick(x.c.id, x.tick.id)
        Repo.rollback(snapshot)
      end)

    {:ok, _} = AsyncWorlds.Clocks.lock_mutations(x.c.id)

    Repo.update!(
      Ecto.Changeset.change(x.tick, status: :resolving, closed_at: provisional.inserted_at)
    )

    old =
      Repo.insert!(%AsyncWorlds.Ticks.Snapshot{
        tick_id: x.tick.id,
        schema_version: 3,
        revision: Ecto.UUID.generate(),
        data: Map.delete(provisional.data, "tension_commitments")
      })

    assert {:ok, %{participation: []}} = TensionCommitments.player_state("123", "999", x.tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(old)
    {:ok, %{draft: draft}} = Ticks.put_draft(x.c.id, x.tick.id, old.revision, payload)
    assert {:ok, _} = Ticks.publish_tick(x.c.id, x.tick.id, draft.id)
  end

  test "combining-character text respects PostgreSQL codepoint limits", x do
    at_limit = String.duplicate("e\u0301", 1000)
    over_limit = at_limit <> "e\u0301"

    assert {:error, :invalid_commitment} =
             change(x, x.a, 0, :edit, %{"intention" => over_limit})

    assert {:error, :invalid_commitment} =
             change(x, x.a, 0, :edit, %{"intention" => "safe", "approach" => over_limit})

    assert {:ok, %{version: 1}} =
             change(x, x.a, 0, :edit, %{"intention" => at_limit, "approach" => at_limit})

    for attrs <- [
          %{"intention" => over_limit},
          %{"intention" => "safe", "approach" => over_limit}
        ] do
      assert {:error, :invalid_commitment} = change(x, x.a, 1, :edit, attrs)
    end

    assert {:ok, %{version: 2}} = change(x, x.a, 1, :confirm)
  end

  test "string safety and limits reject without touching versions", x do
    for bad <- ["", "  ", <<255>>, "a" <> <<0>>, String.duplicate("a", 2001), 1, %{}] do
      assert {:error, :invalid_commitment} = change(x, x.a, 0, :edit, %{"intention" => bad})
    end

    for bad <- [<<255>>, <<0>>, String.duplicate("x", 2001), 1] do
      assert {:error, :invalid_commitment} =
               change(x, x.a, 0, :edit, %{"intention" => "safe", "approach" => bad})
    end

    assert {:ok, %{version: 1}} =
             change(x, x.a, 0, :edit, %{"intention" => String.duplicate("🌍", 2000)})

    assert {:error, :stale_commitment} = change(x, x.a, 0, :edit, %{"intention" => "stale"})
    assert {:error, :stale_commitment} = change(x, x.a, "1", :confirm)

    assert {:error, :unknown_command} =
             Commands.route(%{
               name: "intent",
               options: [%{name: "confirm", type: 1, options: []}]
             })
  end
end
