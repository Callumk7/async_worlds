defmodule AsyncWorlds.Ticks.QuestRollConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Ticks.{Draft, Roll}
  alias AsyncWorlds.Workers.ResolveTick
  alias Ecto.Adapters.SQL.Sandbox

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    campaign =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(900_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        {:ok, character} =
          Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

        {:ok, revision} =
          Quests.create_quest(
            campaign,
            "456",
            %{content_id: "quest", name: "Quest"},
            replace_choice(definition(), rolled())
          )

        {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
        campaign
      end)

    on_exit(fn ->
      db(fn ->
        Repo.transaction(fn ->
          Repo.delete_all(
            from j in Oban.Job,
              where: fragment("?->>'campaign_id' = ?", j.args, ^to_string(campaign.id))
          )

          Repo.delete_all(
            from s in AsyncWorlds.Quests.Submission, where: s.campaign_id == ^campaign.id
          )

          Repo.delete_all(
            from p in AsyncWorlds.Quests.Progression, where: p.campaign_id == ^campaign.id
          )

          Repo.query!("ALTER TABLE quest_rolls DISABLE TRIGGER immutable_quest_rolls")

          snapshots =
            from s in AsyncWorlds.Ticks.Snapshot,
              join: t in AsyncWorlds.Ticks.Tick,
              on: t.id == s.tick_id,
              where: t.campaign_id == ^campaign.id,
              select: s.id

          Repo.delete_all(from r in Roll, where: r.snapshot_id in subquery(snapshots))
          Repo.query!("ALTER TABLE quest_rolls ENABLE TRIGGER immutable_quest_rolls")

          Repo.query!(
            "ALTER TABLE quest_revision_nodes DISABLE TRIGGER immutable_quest_revision_nodes"
          )

          Repo.query!("ALTER TABLE quest_revisions DISABLE TRIGGER immutable_quest_revisions")

          revisions =
            from r in AsyncWorlds.Quests.Revision,
              where: r.campaign_id == ^campaign.id,
              select: r.id

          Repo.delete_all(
            from n in "quest_revision_nodes", where: n.revision_id in subquery(revisions)
          )

          Repo.delete_all(
            from r in AsyncWorlds.Quests.Revision, where: r.campaign_id == ^campaign.id
          )

          Repo.query!(
            "ALTER TABLE quest_revision_nodes ENABLE TRIGGER immutable_quest_revision_nodes"
          )

          Repo.query!("ALTER TABLE quest_revisions ENABLE TRIGGER immutable_quest_revisions")

          Repo.delete_all(
            from q in AsyncWorlds.Quests.Quest, where: q.campaign_id == ^campaign.id
          )

          Repo.delete!(Repo.get!(AsyncWorlds.Campaigns.Campaign, campaign.id))
        end)
      end)
    end)

    {tick, snapshot} =
      db(fn ->
        {:ok, tick} = Ticks.open_tick(campaign.id)
        {:ok, state} = Submissions.player_state(campaign.discord_guild_id, "991")
        {:ok, _} = Submissions.submit(campaign.discord_guild_id, "991", state.identity, "roll")
        {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
        {tick, snapshot}
      end)

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    %{campaign: campaign, tick: tick, snapshot: snapshot, supervisor: supervisor}
  end

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

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  test "separate-connection reservations and duplicate workers preserve exactly one pool and one draft",
       c do
    callbacks =
      for value <- [1, 6, 4, 2],
          do: fn ->
            Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn ->
              value
            end)
          end

    results = race(c.supervisor, callbacks)
    assert [{:ok, rolls} | _] = results
    assert Enum.all?(results, &(&1 == {:ok, rolls}))
    assert length(rolls) == 3
    assert Enum.uniq(Enum.map(rolls, & &1["value"])) |> length() == 1

    args = %{
      "campaign_id" => c.campaign.id,
      "tick_id" => c.tick.id,
      "input_revision" => c.snapshot.revision
    }

    assert race(
             c.supervisor,
             for(_ <- 1..4, do: fn -> ResolveTick.perform(%Oban.Job{args: args}) end)
           ) == [:ok, :ok, :ok, :ok]

    db(fn ->
      assert {:ok, draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
      assert draft.payload["rolls"] == rolls
      assert Repo.aggregate(from(r in Roll, where: r.snapshot_id == ^c.snapshot.id), :count) == 3
      assert Repo.aggregate(from(d in Draft, where: d.tick_id == ^c.tick.id), :count) == 1
    end)
  end
end
