defmodule AsyncWorlds.QuestSubmissionsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.Submissions
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    campaign =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(800_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        {:ok, character} =
          Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

        {:ok, revision} =
          Quests.create_quest(campaign, "456", %{content_id: "race", name: "Race"}, definition())

        {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
        campaign
      end)

    on_exit(fn ->
      # Real committed fixtures exercise separate PostgreSQL connections. Only
      # remove this campaign's immutable test content; restore triggers in the
      # same transaction (rollback restores them too on any cleanup failure).
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

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    {:ok, tick} = db(fn -> Ticks.open_tick(campaign.id) end)
    {:ok, state} = db(fn -> Submissions.player_state(campaign.discord_guild_id, "991") end)
    %{campaign: campaign, tick: tick, identity: state.identity, supervisor: supervisor}
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

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  test "persona switch racing submit serializes without writing to the new subject", c do
    alias AsyncWorlds.Discord.DebugSessions
    guild = c.campaign.discord_guild_id
    {:ok, first} = db(fn -> Characters.player_character(guild, "991") end)
    assert first.name == "Player"
    {:ok, characters} = db(fn -> Characters.list_characters(c.campaign, "456") end)
    original = hd(characters)
    {:ok, other} = db(fn -> Characters.create_character(c.campaign, "456", %{name: "Other"}) end)
    {:ok, _} = db(fn -> DebugSessions.transition(guild, "456", {:player, original.id}) end)
    {:ok, context} = db(fn -> AsyncWorlds.PlayerAccess.context(c.campaign, "456") end)

    [result, {:ok, switched}] =
      race(c.supervisor, [
        fn -> Submissions.submit(guild, context.access, c.identity, "loop") end,
        fn -> DebugSessions.transition(guild, "456", {:player, other.id}) end
      ])

    assert switched.character_id == other.id
    assert match?({:ok, _}, result) or result == {:error, :stale_component}

    submissions =
      db(fn ->
        Repo.all(from s in AsyncWorlds.Quests.Submission, where: s.campaign_id == ^c.campaign.id)
      end)

    assert Enum.all?(submissions, &(&1.character_id == original.id))
    assert length(submissions) == if(match?({:ok, _}, result), do: 1, else: 0)

    assert {:error, :stale_component} =
             db(fn -> Submissions.clear(guild, context.access, c.identity) end)
  end

  defp expected_choice({:ok, _}, :clear), do: nil
  defp expected_choice({:ok, _}, :replace), do: "finish"
  defp expected_choice({:ok, _}, :submit), do: "loop"
  defp expected_choice({:error, :tick_closed}, :submit), do: nil
  defp expected_choice({:error, :tick_closed}, _), do: "loop"

  for operation <- [:submit, :replace, :clear] do
    @operation operation
    test "#{operation} racing close is frozen or explicitly rejected", c do
      guild = c.campaign.discord_guild_id

      if @operation != :submit do
        {:ok, _} = db(fn -> Submissions.submit(guild, "991", c.identity, "loop") end)
      end

      mutation = fn ->
        case @operation do
          :submit -> Submissions.submit(guild, "991", c.identity, "loop")
          :replace -> Submissions.submit(guild, "991", c.identity, "finish")
          :clear -> Submissions.clear(guild, "991", c.identity)
        end
      end

      [result, {:ok, %{snapshot: snapshot}}] =
        race(c.supervisor, [mutation, fn -> Ticks.close_tick(c.campaign.id, c.tick.id) end])

      expected = expected_choice(result, @operation)
      choices = Enum.map(snapshot.data["quest_inputs"]["submissions"], & &1["choice_id"])
      assert choices == if(expected, do: [expected], else: [])

      assert {:ok, %{snapshot: ^snapshot}} =
               db(fn -> Ticks.close_tick(c.campaign.id, c.tick.id) end)

      assert {:error, :tick_closed} = db(fn -> Submissions.clear(guild, "991", c.identity) end)
    end
  end
end
