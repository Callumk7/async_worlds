defmodule AsyncWorlds.Workers.ResolveTickTest do
  use AsyncWorlds.DataCase, async: false
  use Oban.Testing, repo: AsyncWorlds.Repo
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Ticks}
  alias AsyncWorlds.Quests.Submissions
  import AsyncWorlds.QuestFixtures
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

  defp add_quest_input(kind, id) do
    campaign = Repo.get!(AsyncWorlds.Campaigns.Campaign, id)

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "quest", name: "Quest"}, definition())

    {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)

    case kind do
      :submission ->
        {:ok, state} = Submissions.player_state("123", "991")
        {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")

      :trigger ->
        {:ok, clock} = Clocks.create_clock(id, %{name: "Trigger", segments: 4, filled: 4}, "dm")

        {:ok, _} =
          Quests.configure_clock_triggers(campaign, "456", clock.id, [
            %{type: :unlock_quest, character_id: character.id, quest_id: revision.quest_id}
          ])
    end
  end

  for kind <- [:submission, :trigger] do
    @kind kind
    test "#{@kind} work resolves and restart/retries preserve the draft", %{
      campaign: id,
      tick: tick
    } do
      add_quest_input(@kind, id)
      opts = [name: __MODULE__.Oban, repo: AsyncWorlds.Repo, testing: :manual]
      start_supervised!({Oban, opts})
      {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
      args = %{campaign_id: id, tick_id: tick.id, input_revision: snapshot.revision}
      assert :ok = perform_job(ResolveTick, args)
      assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(id, tick.id)
      assert {:ok, draft} = Ticks.fetch_draft(id, tick.id)
      assert draft.payload["schema_version"] == 3
      for _ <- 1..12, do: assert(:ok == perform_job(ResolveTick, args))
      assert {:ok, ^snapshot} = Ticks.fetch_snapshot(id, tick.id)
      assert :ok = stop_supervised(__MODULE__.Oban)
      start_supervised!({Oban, opts})

      assert {:error, :tick_locked} =
               Clocks.create_clock(id, %{name: "Locked", segments: 4}, "dm")

      assert %{success: 1, snoozed: 0} =
               Oban.drain_queue(__MODULE__.Oban, queue: :resolution, with_scheduled: true)

      {:ok, [finished]} = Ticks.resolution_jobs(id, tick.id)
      assert finished.state == "completed"
      assert {:ok, ^draft} = Ticks.fetch_draft(id, tick.id)
    end
  end

  for kind <- [:submission, :trigger] do
    @kind kind
    test "#{@kind} flag overflow cancels distinctly and preserves frozen input and dice", %{
      campaign: id,
      tick: tick
    } do
      campaign = Repo.get!(AsyncWorlds.Campaigns.Campaign, id)
      flags = Map.new(1..100, &{"flag_#{&1}", flag()})

      {:ok, character} =
        Characters.create_character(campaign, "456", %{
          name: "At flag capacity",
          discord_user_id: "991",
          flags: flags
        })

      effect = %{"type" => "set_flag", "key" => "overflow", "flag" => flag()}
      choice = rolled()

      outcomes =
        Map.new(choice["outcomes"], fn {key, value} ->
          {key, Map.put(value, "effects", if(@kind == :submission, do: [effect], else: []))}
        end)

      choice = Map.merge(choice, %{"outcomes" => outcomes, "critical_effects" => []})

      {:ok, revision} =
        Quests.create_quest(
          campaign,
          "456",
          %{content_id: "overflow", name: "Overflow"},
          replace_choice(definition(), choice)
        )

      {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
      {:ok, state} = Submissions.player_state("123", "991")
      {:ok, _} = Submissions.submit("123", "991", state.identity, "roll")

      if @kind == :trigger do
        {:ok, clock} = Clocks.create_clock(id, %{name: "Overflow", segments: 4, filled: 4}, "dm")

        {:ok, _} =
          Quests.configure_clock_triggers(campaign, "456", clock.id, [
            %{type: :set_flag, character_id: character.id, key: "overflow", flag: flag()}
          ])
      end

      {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
      opts = [name: __MODULE__.Oban, repo: AsyncWorlds.Repo, testing: :manual]
      start_supervised!({Oban, opts})

      assert %{cancelled: 1, failure: 0} =
               Oban.drain_queue(__MODULE__.Oban, queue: :resolution)

      assert {:ok, [job]} = Ticks.resolution_jobs(id, tick.id)
      assert job.state == "cancelled"
      assert inspect(job.errors) =~ "invalid_flags"
      assert {:ok, rolls} = Ticks.record_quest_rolls(id, tick.id, snapshot.revision)
      assert length(rolls) == 3

      assert :ok = Oban.retry_job(__MODULE__.Oban, job.id)

      assert %{cancelled: 1, failure: 0} =
               Oban.drain_queue(__MODULE__.Oban, queue: :resolution)

      assert {:ok, ^rolls} = Ticks.record_quest_rolls(id, tick.id, snapshot.revision)
      assert {:ok, ^snapshot} = Ticks.fetch_snapshot(id, tick.id)
      assert {:ok, %{status: :resolving}} = Ticks.fetch_tick(id, tick.id)
      assert {:error, :no_draft} = Ticks.fetch_draft(id, tick.id)

      assert {:error, :tick_locked} =
               Characters.clear_flag(campaign, "456", character.id, "flag_1")

      assert Repo.get!(AsyncWorlds.Characters.Character, character.id).flags == flags
    end
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
