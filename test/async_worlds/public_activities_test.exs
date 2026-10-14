defmodule AsyncWorlds.PublicActivitiesTest do
  use AsyncWorlds.DataCase, async: true

  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.{Progression, Revision}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign}
  end

  defp character(campaign, name, owner) do
    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: name, discord_user_id: owner})

    character
  end

  defp content(summary) do
    update_in(definition(), ["nodes", Access.at(0)], &Map.put(&1, "public_summary", summary))
  end

  test "roster uses pinned public text, retains no-decision states and excludes private content",
       %{campaign: campaign} do
    scout = character(campaign, "Scout", "991")
    ended = character(campaign, "Ended", "992")
    completed = character(campaign, "Completed", "993")
    idle = character(campaign, "Idle", "994")
    legacy = character(campaign, "Legacy", "995")

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Secret quest name", content_id: "harbor"},
        content("Investigating the harbour")
      )

    {:ok, pinned} = Quests.assign(campaign, "456", scout.id, revision.id)
    {:ok, ended_path} = Quests.assign(campaign, "456", ended.id, revision.id)
    {:ok, _} = Quests.end_quest(campaign, "456", ended_path.id)
    {:ok, ending_path} = Quests.assign(campaign, "456", completed.id, revision.id)
    {:ok, _} = Quests.move(campaign, "456", ending_path.id, "end")

    {:ok, old} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Legacy secret", content_id: "legacy"},
        definition()
      )

    {:ok, _} = Quests.assign(campaign, "456", legacy.id, old.id)

    {:ok, newer} =
      Quests.append_revision(
        campaign,
        "456",
        revision.quest_id,
        content("Different public activity")
      )

    assert {:ok, rows} = Quests.public_activities(campaign, "456")

    assert Enum.map(rows, & &1.character_id) == [
             scout.id,
             ended.id,
             completed.id,
             idle.id,
             legacy.id
           ]

    assert hd(rows) == %{
             character_id: scout.id,
             name: "Scout",
             summary: "Investigating the harbour",
             decision_required: true
           }

    for row <- Enum.slice(rows, 1, 3),
        do: assert(row.summary == "No quest decision required." and not row.decision_required)

    assert List.last(rows).summary == "A quest decision is required."

    for row <- rows,
        do:
          assert(Enum.sort(Map.keys(row)) == [:character_id, :decision_required, :name, :summary])

    assert Repo.get!(Progression, pinned.id) == pinned
    assert Repo.get!(Revision, revision.id).definition == content("Investigating the harbour")
    assert newer.number == 2

    # Completing an older path must not hide a newly active assignment.
    {:ok, _} = Quests.assign(campaign, "456", completed.id, newer.id)
    {:ok, updated} = Quests.public_activities(campaign, "456")
    assert Enum.find(updated, &(&1.character_id == completed.id)).decision_required
  end

  test "summary import appends without changing legacy assignments or frozen inputs", %{
    campaign: campaign
  } do
    scout = character(campaign, "Scout", "991")

    doc = fn definition ->
      Jason.encode!(%{
        "version" => 1,
        "quests" => [%{"content_id" => "harbor", "name" => "Harbor", "definition" => definition}]
      })
    end

    {:ok, [first]} = Quests.import_json(campaign, "456", doc.(definition()))
    {:ok, pinned} = Quests.assign(campaign, "456", scout.id, first.revision.id)
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, [second]} = Quests.import_json(campaign, "456", doc.(content("Public activity")))
    assert second.action == :appended
    assert Repo.get!(Progression, pinned.id) == pinned
    assert Repo.get!(AsyncWorlds.Ticks.Snapshot, snapshot.id) == snapshot

    assert {:ok, [%{summary: "A quest decision is required."}]} =
             Quests.public_activities(campaign, "456")

    assert {:ok, _} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
  end

  test "summary-bearing pinned definitions survive freeze and resolution", %{campaign: campaign} do
    scout = character(campaign, "Scout", "991")

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Harbor", content_id: "harbor"},
        content("Public activity")
      )

    {:ok, _} = Quests.assign(campaign, "456", scout.id, revision.id)
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    assert {:ok, _} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    assert Repo.get!(Revision, revision.id).definition == content("Public activity")
  end

  test "fresh authorization isolates campaigns and stale identities cannot expose roster", %{
    campaign: campaign
  } do
    character(campaign, "Local", "991")

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, _} =
      Characters.create_character(other, "457", %{name: "Foreign", discord_user_id: "992"})

    assert {:error, :unauthorized} = Quests.public_activities(campaign, "991")
    assert {:error, :unauthorized} = Quests.public_activities(other, "456")
    assert {:ok, [%{name: "Local"}]} = Quests.public_activities(campaign, "456")
    assert {:ok, [%{name: "Foreign"}]} = Quests.public_activities(other, "457")
    Repo.update!(Ecto.Changeset.change(campaign, dm_user_id: "999"))
    assert {:error, :unauthorized} = Quests.public_activities(campaign, "456")
  end
end
