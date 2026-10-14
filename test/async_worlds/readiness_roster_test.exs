defmodule AsyncWorlds.ReadinessRosterTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Ticks}
  alias AsyncWorlds.Quests.Submissions

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, a} = Characters.create_character(campaign, "456", %{name: "A", discord_user_id: "991"})
    {:ok, b} = Characters.create_character(campaign, "456", %{name: "B", discord_user_id: "992"})

    {:ok, unassigned} =
      Characters.create_character(campaign, "456", %{name: "DM puppet", discord_user_id: nil})

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "quest", name: "Quest"}, definition())

    {:ok, _} = Quests.assign(campaign, "456", a.id, revision.id)
    {:ok, _} = Quests.assign(campaign, "456", unassigned.id, revision.id)
    {:ok, tick} = Ticks.open_tick(campaign.id)

    %{campaign: campaign, a: a, b: b, unassigned: unassigned, revision: revision, tick: tick}
  end

  defp roster(campaign, tick), do: Submissions.readiness_roster(campaign, "456", tick.id)

  defp row(roster, character_id), do: Enum.find(roster.rows, &(&1.character_id == character_id))

  test "roster tracks submit, replace and clear while matching readiness counts", c do
    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert roster.tick_number == c.tick.number
    refute roster.frozen
    assert length(roster.rows) == 3
    assert roster.counts == %{active: 2, submitted: 0, missing: 2}

    assert row(roster, c.a.id).state == :missing
    assert row(roster, c.a.id).quest_name == "Quest"
    assert row(roster, c.a.id).node_id == "hub"
    assert row(roster, c.b.id).state == :no_active_quest
    assert row(roster, c.b.id).quest_name == nil

    {:ok, state} = Submissions.player_state("123", "991")
    assert {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")

    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert row(roster, c.a.id).state == :submitted
    assert roster.counts == %{active: 2, submitted: 1, missing: 1}

    assert {:ok, %{active: 2, submitted: 1, missing: 1}} =
             Submissions.readiness(c.campaign, "456", c.tick.id)

    assert {:ok, _} = Submissions.submit("123", "991", state.identity, "finish")
    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert row(roster, c.a.id).state == :submitted

    assert {:ok, _} = Submissions.clear("123", "991", state.identity)
    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert row(roster, c.a.id).state == :missing
    assert roster.counts == %{active: 2, submitted: 0, missing: 2}
  end

  test "unassigned characters are flagged distinctly from missing player choices", c do
    assert {:ok, roster} = roster(c.campaign, c.tick)

    unassigned = row(roster, c.unassigned.id)
    assert unassigned.state == :missing
    assert unassigned.unassigned
    assert unassigned.discord_user_id == nil

    player = row(roster, c.a.id)
    assert player.state == :missing
    refute player.unassigned
    assert player.discord_user_id == "991"

    # Unassigned characters still agree with the domain readiness counts.
    assert roster.counts.missing == 2
  end

  test "an invalidated earlier choice is missing, never submitted", c do
    gated =
      choice("gated", "end")
      |> Map.put("conditions", [
        %{"type" => "character_flag", "key" => "vip", "flag_type" => "boolean", "value" => true}
      ])

    {:ok, revision} =
      Quests.create_quest(
        c.campaign,
        "456",
        %{content_id: "gated", name: "Gated"},
        replace_choice(definition(), gated)
      )

    {:ok, vip} =
      Characters.create_character(c.campaign, "456", %{
        name: "VIP",
        discord_user_id: "993",
        flags: %{"vip" => flag(true)}
      })

    {:ok, _} = Quests.assign(c.campaign, "456", vip.id, revision.id)
    {:ok, state} = Submissions.player_state("123", "993")
    assert {:ok, _} = Submissions.submit("123", "993", state.identity, "gated")
    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert row(roster, vip.id).state == :submitted

    # Removing the qualifying flag invalidates the recorded choice in place.
    assert {:ok, _} = Characters.clear_flag(c.campaign, "456", vip.id, "vip")
    assert {:ok, roster} = roster(c.campaign, c.tick)
    invalidated = row(roster, vip.id)
    assert invalidated.state == :missing
    assert invalidated.invalidated
    refute row(roster, c.a.id).invalidated

    assert {:ok, %{submitted: 0} = counts} = Submissions.readiness(c.campaign, "456", c.tick.id)
    assert counts == roster.counts
  end

  test "DM interventions transition roster states", c do
    assert {:ok, _} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert row(roster, c.b.id).state == :missing

    assert {:ok, ended} = Quests.end_quest(c.campaign, "456", progression_id(c.campaign, c.b.id))
    assert ended.status == :ended

    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert row(roster, c.b.id).state == :no_active_quest
    assert roster.counts == %{active: 2, submitted: 0, missing: 2}
  end

  test "closed ticks report the frozen snapshot, not live state", c do
    {:ok, state} = Submissions.player_state("123", "991")
    assert {:ok, _} = Submissions.submit("123", "991", state.identity, "finish")
    assert {:ok, %{snapshot: _}} = Ticks.close_tick(c.campaign.id, c.tick.id)

    assert {:ok, roster} = roster(c.campaign, c.tick)
    assert roster.frozen
    assert row(roster, c.a.id).state == :submitted
    assert row(roster, c.unassigned.id).state == :missing
    assert roster.counts == %{active: 2, submitted: 1, missing: 1}

    # Management is locked while frozen, so the frozen roster cannot drift.
    assert {:error, :tick_locked} =
             Quests.end_quest(c.campaign, "456", progression_id(c.campaign, c.unassigned.id))

    assert {:ok, frozen_again} = roster(c.campaign, c.tick)
    assert frozen_again.rows == roster.rows
  end

  test "roster is DM-only and rejects malformed actors", c do
    assert {:error, :unauthorized} = Submissions.readiness_roster(c.campaign, "991", c.tick.id)
    assert {:error, :invalid_id} = Submissions.readiness_roster(c.campaign, "abc", c.tick.id)
    assert {:error, :not_found} = Submissions.readiness_roster(c.campaign, "456", -1)

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "999",
        public_channel_id: "788"
      })

    assert {:error, :not_found} = Submissions.readiness_roster(other, "999", c.tick.id)
  end

  defp progression_id(campaign, character_id) do
    AsyncWorlds.Repo.get_by!(AsyncWorlds.Quests.Progression,
      campaign_id: campaign.id,
      character_id: character_id,
      status: :active
    ).id
  end
end
