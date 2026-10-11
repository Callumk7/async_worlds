defmodule AsyncWorlds.QuestInterventionsTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Ticks}
  alias AsyncWorlds.Quests.{Intervention, Progression, Submissions}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, a} = Characters.create_character(campaign, "456", %{name: "A", discord_user_id: "991"})
    {:ok, b} = Characters.create_character(campaign, "456", %{name: "B", discord_user_id: "992"})

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "quest", name: "Quest"}, definition())

    %{campaign: campaign, a: a, b: b, revision: revision}
  end

  test "assignment is independently audited per character and explicit reasons are validated",
       c do
    assert {:error, :invalid_reason} =
             Quests.assign(c.campaign, "456", c.a.id, c.revision.id, reason: " ")

    assert {:error, :invalid_reason} =
             Quests.assign(c.campaign, "456", c.a.id, c.revision.id,
               reason: String.duplicate("x", 2001)
             )

    assert {:error, :invalid_reason} =
             Quests.assign(c.campaign, "456", c.a.id, c.revision.id, reason: "bad\u0000reason")

    assert {:ok, []} = Quests.list_interventions(c.campaign, "456", c.a.id)

    assert {:ok, a} =
             Quests.assign(c.campaign, "456", c.a.id, c.revision.id,
               reason: "  Introduce the story  ",
               expected_progression: nil
             )

    assert {:ok, b} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
    assert a.id != b.id
    assert {:ok, [audit]} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert audit.operation == "assign"
    assert audit.actor_id == "456"
    assert audit.reason == "Introduce the story"
    assert audit.before == nil
    assert audit.after["id"] == a.id
    assert audit.after["revision_id"] == c.revision.id
    assert audit.after["position_version"] == 1
    assert audit.invalidated_submissions == 0
    assert audit.tick_id == nil
    assert {:error, :active_quest} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assert {:ok, [^audit]} = Quests.list_interventions(c.campaign, "456", c.a.id)
  end

  test "move, swap and end record exact positions and invalidated choices atomically", c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, other} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")
    {:ok, audits} = Quests.list_interventions(c.campaign, "456", c.a.id)

    assert {:ok, ^p} =
             Quests.move(c.campaign, "456", p.id, "hub",
               reason: "No change",
               expected_progression: p
             )

    assert {:ok, ^audits} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")

    assert {:ok, moved} =
             Quests.move(c.campaign, "456", p.id, "end",
               reason: "Session ending",
               expected_progression: p
             )

    assert moved.status == :completed
    assert {:ok, [move | _]} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert move.before["node_id"] == "hub"
    assert move.after["node_id"] == "end"
    assert move.after["status"] == "completed"
    assert move.invalidated_submissions == 1
    assert move.tick_id == tick.id
    assert Repo.get!(Progression, other.id) == other
    {:ok, assigned} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")

    assert {:ok, swapped} =
             Quests.swap(c.campaign, "456", c.a.id, c.revision.id,
               reason: "Restart after session",
               expected_progression: assigned
             )

    assert Repo.get!(Progression, assigned.id).status == :ended
    assert {:ok, [swap | _]} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert swap.before["id"] == assigned.id
    assert swap.after["id"] == swapped.id
    assert swap.invalidated_submissions == 1
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "finish")

    assert {:ok, _} =
             Quests.end_quest(c.campaign, "456", swapped.id,
               reason: "Pause personal story",
               expected_progression: swapped
             )

    assert {:ok, [ended | _]} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert ended.operation == "end"
    assert ended.after["status"] == "ended"
    assert ended.invalidated_submissions == 1
  end

  test "invalid and stale interventions retain choices and cannot append a misleading audit", c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")
    {:ok, audits} = Quests.list_interventions(c.campaign, "456", c.a.id)

    assert {:error, :invalid_node} =
             Quests.move(c.campaign, "456", p.id, "foreign", reason: "Bad link")

    assert {:error, :not_found} =
             Quests.swap(c.campaign, "456", c.a.id, 99999, reason: "Bad revision")

    assert {:error, :stale_progression} =
             Quests.swap(c.campaign, "456", c.a.id, c.revision.id, expected_progression: nil)

    assert {:error, :stale_progression} =
             Quests.assign(c.campaign, "456", c.a.id, c.revision.id, expected_progression: nil)

    assert {:error, :invalid_reason} = Quests.end_quest(c.campaign, "456", p.id, reason: nil)
    assert {:ok, ^audits} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")
    {:ok, moved} = Quests.move(c.campaign, "456", p.id, "end")

    assert {:error, :stale_progression} =
             Quests.end_quest(c.campaign, "456", p.id, expected_progression: p)

    assert {:error, :stale_progression} =
             Quests.move(c.campaign, "456", p.id, "hub", expected_progression: p)

    assert Repo.get!(Progression, p.id) == moved
  end

  test "operational readers freshly authorize DM, scope revisions/characters/audits, and audit is immutable",
       c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Characters.create_character(other, "457", %{name: "Foreign", discord_user_id: "993"})

    {:ok, _} =
      Quests.create_quest(other, "457", %{content_id: "foreign", name: "Foreign"}, definition())

    assert {:ok, state} = Quests.management_state(c.campaign, "456", c.a.id)
    assert length(state.characters) == 2
    assert Enum.map(state.revisions, & &1.id) == [c.revision.id]
    assert state.selected.progression == p
    assert state.selected.revision.id == c.revision.id
    assert {:error, :not_found} = Quests.management_state(c.campaign, "456", foreign.id)
    assert {:error, :not_found} = Quests.list_interventions(c.campaign, "456", foreign.id)
    assert {:error, :unauthorized} = Quests.management_state(c.campaign, "991")
    assert {:error, :unauthorized} = Quests.list_interventions(c.campaign, "991", c.a.id)
    [audit] = state.audits

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE quest_interventions SET reason = 'tamper' WHERE id = $1", [audit.id],
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!("DELETE FROM quest_interventions WHERE id = $1", [audit.id], mode: :savepoint)
    end

    assert Repo.get!(Intervention, audit.id) == audit
    assert {:ok, payload} = Quests.player_quest("123", "991")
    assert Enum.sort(Map.keys(payload)) == [:choices, :completed, :text]

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "458",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = Quests.management_state(c.campaign, "456")
    assert {:ok, [^audit]} = Quests.list_interventions(c.campaign, "458", c.a.id)
  end

  test "resolving and review locks reject changes and audits while preserving frozen input", c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, audits} = Quests.list_interventions(c.campaign, "456", c.a.id)

    for stage <- [:resolving, :in_review] do
      if stage == :in_review do
        {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
        {:ok, _} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
      end

      assert {:error, :tick_locked} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
      assert {:error, :tick_locked} = Quests.swap(c.campaign, "456", c.a.id, c.revision.id)
      assert {:error, :tick_locked} = Quests.move(c.campaign, "456", p.id, "end")
      assert {:error, :tick_locked} = Quests.end_quest(c.campaign, "456", p.id)
      assert {:ok, ^audits} = Quests.list_interventions(c.campaign, "456", c.a.id)
      assert {:ok, %{locked: true}} = Quests.management_state(c.campaign, "456", c.a.id)
      assert {:ok, ^snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)
      assert Repo.get!(Progression, p.id) == p
    end
  end
end
