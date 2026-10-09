defmodule AsyncWorlds.TicksConcurrencyTest do
  use ExUnit.Case, async: false
  alias AsyncWorlds.{Campaigns, Clocks, Repo, Ticks}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Ticks.{Draft, Snapshot, Tick}
  alias Ecto.Adapters.SQL.Sandbox
  import Ecto.Query
  import Ecto.Changeset

  # Unlike shared-sandbox tasks, these workers use separate connections and real
  # committed transactions, so PostgreSQL row locks and unique indexes are exercised.
  setup do
    campaign =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(900_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        campaign
      end)

    on_exit(fn -> db(fn -> Repo.delete!(Repo.get!(Campaign, campaign.id)) end) end)
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    %{campaign: campaign.id, supervisor: supervisor}
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp race(supervisor, functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          db(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> fun.()
            end
          end)
        end)
      end)

    Enum.each(tasks, fn task ->
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10000))
  end

  test "concurrent opens create exactly one active tick", %{campaign: id, supervisor: supervisor} do
    results = race(supervisor, List.duplicate(fn -> Ticks.open_tick(id) end, 4))
    assert Enum.count(results, &match?({:ok, %Tick{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :active_tick})) == 3
    assert db(fn -> Repo.aggregate(from(t in Tick, where: t.campaign_id == ^id), :count) end) == 1
  end

  test "concurrent close retries return one immutable snapshot", %{
    campaign: id,
    supervisor: supervisor
  } do
    {:ok, tick} = db(fn -> Ticks.open_tick(id) end)
    results = race(supervisor, List.duplicate(fn -> Ticks.close_tick(id, tick.id) end, 4))

    assert Enum.all?(
             results,
             &match?({:ok, %{tick: %Tick{status: :resolving}, snapshot: %Snapshot{}}}, &1)
           )

    snapshots = Enum.map(results, fn {:ok, result} -> result.snapshot end)
    assert length(Enum.uniq(snapshots)) == 1

    assert db(fn -> Repo.aggregate(from(s in Snapshot, where: s.tick_id == ^tick.id), :count) end) ==
             1

    assert db(fn -> Repo.get!(Campaign, id).clock_mutations_locked end)
  end

  test "clock edit either precedes snapshot or is rejected, never lost at close", %{
    campaign: id,
    supervisor: supervisor
  } do
    {:ok, clock} = db(fn -> Clocks.create_clock(id, %{name: "Race", segments: 4}, "dm") end)
    {:ok, tick} = db(fn -> Ticks.open_tick(id) end)

    [edit_result, {:ok, %{snapshot: snapshot}}] =
      race(supervisor, [
        fn -> Clocks.adjust_clock(id, clock.id, 1, "dm") end,
        fn -> Ticks.close_tick(id, tick.id) end
      ])

    expected =
      case edit_result do
        {:ok, %Clock{filled: 1}} -> 1
        {:error, :tick_locked} -> 0
      end

    assert hd(snapshot.data["clocks"])["filled"] == expected
    assert db(fn -> Repo.get!(Clock, clock.id).filled end) == expected
  end

  test "review edit and publication cannot silently overwrite each other", %{
    campaign: id,
    supervisor: supervisor
  } do
    {:ok, tick} = db(fn -> Ticks.open_tick(id) end)
    {:ok, %{snapshot: snapshot}} = db(fn -> Ticks.close_tick(id, tick.id) end)
    {:ok, %{draft: draft}} = db(fn -> Ticks.put_draft(id, tick.id, snapshot.revision, %{}) end)

    [edited, published] =
      race(supervisor, [
        fn ->
          Ticks.put_draft(id, tick.id, snapshot.revision, %{world_news: "Edited"}, draft.id)
        end,
        fn -> Ticks.publish_tick(id, tick.id, draft.id, fn _ -> {:ok, :applied} end) end
      ])

    case {edited, published} do
      {{:ok, %{draft: %Draft{revision: 2}}}, {:error, :stale_draft}} ->
        assert db(fn -> Repo.get!(Tick, tick.id).status end) == :in_review
        assert db(fn -> Ticks.fetch_draft(id, tick.id) end) |> elem(1) |> Map.get(:revision) == 2

      {{:error, {:invalid_transition, :published, :put_draft}}, {:ok, %Tick{status: :published}}} ->
        assert db(fn -> Repo.get!(Tick, tick.id).draft_revision end) == 1
    end
  end

  test "concurrent resolution writes reject stale workers", %{
    campaign: id,
    supervisor: supervisor
  } do
    {:ok, tick} = db(fn -> Ticks.open_tick(id) end)
    {:ok, %{snapshot: snapshot}} = db(fn -> Ticks.close_tick(id, tick.id) end)

    results =
      race(
        supervisor,
        List.duplicate(fn -> Ticks.put_draft(id, tick.id, snapshot.revision, %{}) end, 3)
      )

    assert Enum.count(results, &match?({:ok, %{draft: %Draft{revision: 1}}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_draft})) == 2

    assert db(fn -> Repo.aggregate(from(d in Draft, where: d.tick_id == ^tick.id), :count) end) ==
             1
  end

  test "concurrent publication runs database effects once and advances number once", %{
    campaign: id,
    supervisor: supervisor
  } do
    {:ok, clock} = db(fn -> Clocks.create_clock(id, %{name: "World", segments: 4}, "dm") end)
    {:ok, tick} = db(fn -> Ticks.open_tick(id) end)
    {:ok, %{snapshot: snapshot}} = db(fn -> Ticks.close_tick(id, tick.id) end)
    {:ok, %{draft: draft}} = db(fn -> Ticks.put_draft(id, tick.id, snapshot.revision, %{}) end)

    results =
      race(
        supervisor,
        List.duplicate(
          fn ->
            Ticks.publish_tick(id, tick.id, draft.id, fn _ ->
              live = Repo.get!(Clock, clock.id)
              Repo.update!(change(live, filled: live.filled + 1))
              {:ok, :applied}
            end)
          end,
          3
        )
      )

    assert Enum.count(results, &match?({:ok, %Tick{status: :published}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_published})) == 2
    assert db(fn -> Repo.get!(Clock, clock.id).filled end) == 1
    assert db(fn -> Repo.get!(Campaign, id).current_tick_number end) == 1
    refute db(fn -> Repo.get!(Campaign, id).clock_mutations_locked end)
  end
end
