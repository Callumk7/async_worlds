defmodule AsyncWorlds.Ticks.OpeningTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo}
  alias AsyncWorlds.DM.Ticks

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign, scope: %{campaign: campaign, discord_user_id: "456"}}
  end

  defp rows(table), do: Repo.aggregate(table, :count)

  defp write_counts do
    Enum.map(
      [
        AsyncWorlds.Ticks.Tick,
        AsyncWorlds.Deliveries.Delivery,
        Oban.Job,
        AsyncWorlds.Clocks.Audit,
        AsyncWorlds.Quests.Progression
      ],
      &rows/1
    )
  end

  defp add_character(campaign, name, owner) do
    {:ok, c} = Characters.create_character(campaign, "456", %{name: name, discord_user_id: owner})
    c
  end

  test "empty preparation and repeat exact preview perform no writes", %{scope: scope} do
    before = write_counts()
    assert {:ok, prepared} = Ticks.prepare_opening(scope)
    assert prepared.tick_number == 1
    assert prepared.public_channel_id == "789"
    assert hd(prepared.messages).content =~ "No characters"
    assert {:ok, ^prepared} = Ticks.preview_opening(scope, prepared.token)
    assert {:ok, ^prepared} = Ticks.preview_opening(scope, prepared.token)
    assert write_counts() == before
    assert {:ok, nil} = Ticks.active_tick(scope)
  end

  test "mixed roster uses pinned summaries, no-decision states and independent opening narration",
       %{scope: scope, campaign: c} do
    scout = add_character(c, "Scout", "991")
    idle = add_character(c, "Idle", "992")
    ended = add_character(c, "Ended", "993")
    completed = add_character(c, "Completed", "994")
    dm = add_character(c, "DM-controlled", nil)
    legacy = add_character(c, "Legacy", "995")

    public =
      update_in(
        definition(),
        ["nodes", Access.at(0)],
        &Map.put(&1, "public_summary", "Public harbour work")
      )

    {:ok, revision} =
      Quests.create_quest(c, "456", %{name: "SECRET quest", content_id: "quest"}, public)

    for char <- [scout, ended, completed, dm],
        do: assert({:ok, _} = Quests.assign(c, "456", char.id, revision.id))

    ended_path = Repo.get_by!(AsyncWorlds.Quests.Progression, character_id: ended.id)
    {:ok, _} = Quests.end_quest(c, "456", ended_path.id)
    completed_path = Repo.get_by!(AsyncWorlds.Quests.Progression, character_id: completed.id)
    {:ok, _} = Quests.move(c, "456", completed_path.id, "end")

    {:ok, old} =
      Quests.create_quest(c, "456", %{name: "SECRET legacy", content_id: "legacy"}, definition())

    {:ok, _} = Quests.assign(c, "456", legacy.id, old.id)

    {:ok, _} =
      Quests.append_revision(
        c,
        "456",
        revision.quest_id,
        update_in(public, ["nodes", Access.at(0), "public_summary"], fn _ -> "NEW unpinned" end)
      )

    before = write_counts()
    assert {:ok, prepared} = Ticks.prepare_opening(scope, %{"narration" => "Independent opening"})
    text = Enum.map_join(prepared.messages, "", & &1.content)

    for name <- [scout.name, idle.name, ended.name, completed.name, dm.name, legacy.name],
        do: assert(text =~ name)

    assert text =~ "Scout: Public harbour work"
    assert text =~ "Idle: No quest decision required."
    assert text =~ "Ended: No quest decision required."
    assert text =~ "DM handles this quest decision"
    assert text =~ "Legacy: A quest decision is required."
    assert text =~ "Independent opening"
    refute text =~ "SECRET"
    refute text =~ "NEW unpinned"
    assert write_counts() == before
  end

  test "stale generation including ABA rejects preview/open without writes; deliberate reprepare opens",
       %{scope: scope, campaign: c} do
    char = add_character(c, "Old", "991")
    {:ok, prepared} = Ticks.prepare_opening(scope)
    {:ok, _} = Characters.update_character(c, "456", char.id, %{name: "New"})
    {:ok, _} = Characters.update_character(c, "456", char.id, %{name: "Old"})
    before = write_counts()
    assert {:error, :stale_preparation} = Ticks.preview_opening(scope, prepared.token)
    assert {:error, :stale_preparation} = Ticks.open_prepared_tick(scope, prepared.token)
    assert write_counts() == before
    {:ok, fresh} = Ticks.prepare_opening(scope)
    assert fresh.version != prepared.version
    assert {:ok, tick} = Ticks.open_prepared_tick(scope, fresh.token)
    assert tick.number == fresh.tick_number
    assert {:error, :active_tick} = Ticks.open_prepared_tick(scope, fresh.token)
    # ENG-64 does not enqueue the prepared briefing.
    deliveries = Repo.all(AsyncWorlds.Deliveries.Delivery)
    assert Enum.any?(deliveries, &(&1.content == "Tick 1 is now open."))
    refute Enum.any?(deliveries, &String.contains?(&1.content, "No resource assignment command"))
  end

  test "readiness/version detects assignments, flag eligibility and clock changes", %{
    scope: scope,
    campaign: c
  } do
    char = add_character(c, "Scout", "991")
    {:ok, initial} = Ticks.prepare_opening(scope)

    {:ok, rev} =
      Quests.create_quest(c, "456", %{name: "Quest", content_id: "quest"}, definition())

    {:ok, _} = Quests.assign(c, "456", char.id, rev.id)
    assert {:error, :stale_preparation} = Ticks.open_prepared_tick(scope, initial.token)
    {:ok, assigned} = Ticks.prepare_opening(scope)

    {:ok, _} =
      Characters.set_flag(c, "456", char.id, "secret", %{
        "type" => "boolean",
        "value" => true,
        "player_visible" => false
      })

    assert {:error, :stale_preparation} = Ticks.preview_opening(scope, assigned.token)
    {:ok, flagged} = Ticks.prepare_opening(scope)

    {:ok, _} =
      AsyncWorlds.DM.Clocks.create_clock(scope, %{
        name: "Hidden",
        segments: 4,
        visibility: :hidden
      })

    assert {:error, :stale_preparation} = Ticks.open_prepared_tick(scope, flagged.token)
  end

  test "authorization, foreign and malformed preparations and invalid inputs reject", %{
    scope: scope,
    campaign: c
  } do
    {:ok, prepared} = Ticks.prepare_opening(scope)

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "456",
        public_channel_id: "790"
      })

    assert {:error, :invalid_preparation} =
             Ticks.preview_opening(%{scope | campaign: other}, prepared.token)

    assert {:error, :invalid_preparation} =
             Ticks.open_prepared_tick(%{scope | campaign: other}, prepared.token)

    expired =
      Phoenix.Token.sign(
        AsyncWorldsWeb.Endpoint,
        "tick-opening-v1",
        {c.id, "456", prepared.version, prepared.narration},
        signed_at: 1
      )

    assert {:error, :invalid_preparation} = Ticks.preview_opening(scope, expired)
    assert {:error, :invalid_preparation} = Ticks.open_prepared_tick(scope, expired)

    assert {:error, :unauthorized} = Ticks.prepare_opening(%{scope | discord_user_id: "999"})

    assert {:error, :invalid_preparation} =
             Ticks.open_prepared_tick(scope, prepared.token <> "bad")

    assert {:error, :invalid_preparation} = Ticks.preview_opening(scope, prepared)

    for attrs <- [
          %{"campaign_id" => other.id},
          %{"world_news" => "Secret"},
          %{"narration" => nil},
          %{"narration" => <<255>>},
          %{"narration" => "a\0b"},
          %{"narration" => String.duplicate("x", 8001)}
        ] do
      assert {:error, :invalid_opening} = Ticks.prepare_opening(scope, attrs)
    end

    changed = Repo.update!(Ecto.Changeset.change(c, public_channel_id: "799"))
    assert {:error, :stale_campaign} = Ticks.preview_opening(scope, prepared.token)

    assert {:error, :stale_preparation} =
             Ticks.open_prepared_tick(%{scope | campaign: changed}, prepared.token)

    Repo.update!(Ecto.Changeset.change(changed, dm_user_id: "999"))
    assert {:error, :unauthorized} = Ticks.open_prepared_tick(scope, prepared.token)
    assert rows(AsyncWorlds.Ticks.Tick) == 0
    assert rows(AsyncWorlds.Deliveries.Delivery) == 0
  end

  test "locked and active campaigns cannot prepare", %{scope: scope, campaign: c} do
    Repo.update!(Ecto.Changeset.change(c, clock_mutations_locked: true))
    assert {:error, :tick_locked} = Ticks.prepare_opening(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Campaigns.Campaign, c.id), clock_mutations_locked: false)
    )

    {:ok, _} = Ticks.open_tick(scope)
    assert {:error, :active_tick} = Ticks.prepare_opening(scope)
  end
end
