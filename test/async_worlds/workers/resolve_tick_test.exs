defmodule AsyncWorlds.Workers.ResolveTickTest do
  use AsyncWorlds.DataCase, async: false
  use Oban.Testing, repo: AsyncWorlds.Repo
  alias AsyncWorlds.{Campaigns, Clocks, Ticks}
  alias AsyncWorlds.Ticks.{Draft, Snapshot}
  alias AsyncWorlds.Workers.ResolveTick

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, tick} = Ticks.open_tick(campaign.id)
    %{campaign: campaign.id, tick: tick}
  end

  test "close persists one job atomically; repeated close never queues another", %{
    campaign: id,
    tick: tick
  } do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
    args = %{campaign_id: id, tick_id: tick.id, input_revision: snapshot.revision}
    assert_enqueued(worker: ResolveTick, args: args)
    assert {:ok, _} = Ticks.close_tick(id, tick.id)
    assert length(all_enqueued(worker: ResolveTick, args: args)) == 1
    assert {:ok, [%Oban.Job{state: "available"}]} = Ticks.resolution_jobs(id, tick.id)
    assert {:error, :not_found} = Ticks.resolution_jobs(-1, tick.id)
  end

  test "rolling back closing rolls back snapshot, lifecycle, lock and job", %{
    campaign: id,
    tick: tick
  } do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = Ticks.close_tick(id, tick.id)
               assert_enqueued(worker: ResolveTick, args: %{tick_id: tick.id})
               Repo.rollback(:abort)
             end)

    assert {:ok, %{status: :open}} = Ticks.fetch_tick(id, tick.id)
    assert {:error, :not_closed} = Ticks.fetch_snapshot(id, tick.id)
    refute_enqueued(worker: ResolveTick, args: %{tick_id: tick.id})
    assert {:ok, _} = Clocks.create_clock(id, %{name: "Unlocked", segments: 4}, "dm")
  end

  test "resolution retries preserve the original and edited draft", %{campaign: id, tick: tick} do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
    args = %{campaign_id: id, tick_id: tick.id, input_revision: snapshot.revision}
    assert :ok = perform_job(ResolveTick, args)
    assert {:ok, %{revision: 1} = draft} = Ticks.fetch_draft(id, tick.id)
    assert :ok = perform_job(ResolveTick, args)
    assert {:ok, ^draft} = Ticks.fetch_draft(id, tick.id)

    assert {:ok, %{draft: edited}} =
             Ticks.put_draft(id, tick.id, snapshot.revision, %{world_news: ["Edited"]}, draft.id)

    assert :ok = perform_job(ResolveTick, args)
    assert {:ok, ^edited} = Ticks.fetch_draft(id, tick.id)
    assert Repo.aggregate(from(d in Draft, where: d.tick_id == ^tick.id), :count) == 2
    assert {:ok, _} = Ticks.publish_tick(id, tick.id, edited.id, fn _ -> {:ok, :test_only} end)
    assert :ok = perform_job(ResolveTick, args)
    assert {:ok, ^edited} = Ticks.fetch_draft(id, tick.id)
  end

  test "pending resolution survives a supervised Oban restart and drains into review", %{
    campaign: id,
    tick: tick
  } do
    opts = [name: __MODULE__.Oban, repo: AsyncWorlds.Repo, testing: :manual]
    start_supervised!({Oban, opts})
    {:ok, _} = Ticks.close_tick(id, tick.id)
    assert :ok = stop_supervised(__MODULE__.Oban)
    start_supervised!({Oban, opts})
    assert %{success: 1, failure: 0} = Oban.drain_queue(__MODULE__.Oban, queue: :resolution)
    assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(id, tick.id)
    assert {:ok, %{revision: 1}} = Ticks.fetch_draft(id, tick.id)
  end

  test "malformed frozen input cancels safely and leaves the tick locked for investigation", %{
    campaign: id,
    tick: tick
  } do
    # Construct unsupported input on insert, never UPDATE the immutable snapshot.
    snapshot =
      Repo.insert!(%Snapshot{
        tick_id: tick.id,
        revision: Ecto.UUID.generate(),
        schema_version: 2,
        data: %{}
      })

    args = %{campaign_id: id, tick_id: tick.id, input_revision: snapshot.revision}
    # An open tick is not resolvable, even when it has an invalid snapshot.
    assert {:cancel, :invalid_transition} = perform_job(ResolveTick, args)
    Repo.update!(Ecto.Changeset.change(tick, status: :resolving, closed_at: DateTime.utc_now()))
    assert {:ok, _} = Clocks.lock_mutations(id)
    assert {:cancel, :invalid_snapshot} = perform_job(ResolveTick, args)
    assert {:ok, %{status: :resolving}} = Ticks.fetch_tick(id, tick.id)
    assert {:error, :tick_locked} = Clocks.create_clock(id, %{name: "Locked", segments: 4}, "dm")

    assert {:cancel, :stale_input} =
             perform_job(ResolveTick, Map.put(args, :input_revision, Ecto.UUID.generate()))

    assert {:cancel, :not_found} =
             perform_job(ResolveTick, %{
               campaign_id: id,
               tick_id: -1,
               input_revision: snapshot.revision
             })
  end
end
