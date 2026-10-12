defmodule AsyncWorlds.Ticks.QuestResolutionIntegrationTest do
  use AsyncWorlds.DataCase, async: false
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Ticks}
  alias AsyncWorlds.Quests.{Progression, Submissions}
  alias AsyncWorlds.Ticks.{QuestDice, Roll, WorldResolver}
  alias AsyncWorlds.Workers.ResolveTick

  setup context do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, clock} = Clocks.create_clock(campaign.id, %{name: "Secret", segments: 4}, "dm")

    choice =
      rolled()
      |> put_in(["outcomes", "success", "effects"], [
        %{"type" => "clock_delta", "clock_id" => clock.id, "delta" => 4}
      ])

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{content_id: "quest", name: "Quest"},
        replace_choice(definition(), choice)
      )

    flags =
      if context[:full_flags],
        do: Map.new(1..100, fn index -> {"flag_#{index}", flag()} end),
        else: %{}

    pairs =
      for user <- ["991", "992"] do
        {:ok, character} =
          Characters.create_character(campaign, "456", %{
            name: "Player",
            discord_user_id: user,
            flags: flags
          })

        {:ok, progression} = Quests.assign(campaign, "456", character.id, revision.id)
        {character, progression}
      end

    {:ok, tick} = Ticks.open_tick(campaign.id)

    for user <- ["991", "992"] do
      {:ok, state} = Submissions.player_state("123", user)
      {:ok, _} = Submissions.submit("123", user, state.identity, "roll")
    end

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    %{campaign: campaign, tick: tick, snapshot: snapshot, pairs: pairs, clock: clock}
  end

  test "dice commit survives a failure before draft, retries consume identical associations; live state unchanged",
       c do
    assert {:ok, rolls} =
             Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn -> 6 end)

    assert length(rolls) == 6
    assert Enum.map(rolls, &Map.drop(&1, ["value"])) == QuestDice.specs(c.snapshot)
    assert Repo.aggregate(Roll, :count) == 6
    assert {:error, :no_draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)

    assert {:ok, ^rolls} =
             Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn ->
               flunk("retry rerolled")
             end)

    args = %{
      "campaign_id" => c.campaign.id,
      "tick_id" => c.tick.id,
      "input_revision" => c.snapshot.revision
    }

    assert :ok = ResolveTick.perform(%Oban.Job{args: args})
    assert {:ok, draft} = Ticks.fetch_draft("123", "456", c.tick.id)
    assert draft.payload["rolls"] == rolls
    assert Enum.all?(draft.payload["private_results"], & &1["critical"])
    assert :ok = ResolveTick.perform(%Oban.Job{args: args})
    assert {:ok, ^draft} = Ticks.fetch_draft("123", "456", c.tick.id)

    for {character, progression} <- c.pairs do
      assert Repo.get!(AsyncWorlds.Characters.Character, character.id) == character
      assert Repo.get!(Progression, progression.id) == progression
      assert {:ok, state} = Submissions.player_state("123", character.discord_user_id)
      refute Map.has_key?(state, :private_results)
      assert state.quest.text == "Hub"
    end

    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 0

    assert {:error, :quest_publication_required} =
             Ticks.publish_tick(c.campaign.id, c.tick.id, draft.id)

    assert {:error, :unauthorized} = Ticks.fetch_draft("123", "991", c.tick.id)
    assert {:error, :not_found} = Ticks.fetch_draft("123", "456", -1)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = Ticks.fetch_draft("123", "456", c.tick.id)
    assert {:ok, ^draft} = Ticks.fetch_draft("123", "457", c.tick.id)
  end

  @tag full_flags: true
  test "a deterministic engine failure cancels and preserves committed dice on operator retry",
       c do
    {:ok, rolls} =
      Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn -> 6 end)

    # The valid frozen characters already have 100 flags. Critical bonus effects
    # exceed the state limit, so the engine fails after dice have been committed.
    assert {:error, :invalid_flags} = WorldResolver.resolve(c.snapshot, %{}, rolls)

    args = %{
      "campaign_id" => c.campaign.id,
      "tick_id" => c.tick.id,
      "input_revision" => c.snapshot.revision
    }

    for _ <- 1..2 do
      assert {:cancel, :invalid_flags} = ResolveTick.perform(%Oban.Job{args: args})
      assert {:error, :no_draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
      assert Repo.aggregate(Roll, :count) == 6

      assert {:ok, ^rolls} =
               Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn ->
                 flunk("failed resolution rerolled committed dice")
               end)
    end

    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 0

    for {character, progression} <- c.pairs do
      assert Repo.get!(AsyncWorlds.Characters.Character, character.id) == character
      assert Repo.get!(Progression, progression.id) == progression
    end
  end

  test "controlled recomputation changes one pool without changing unrelated roll identity/value",
       c do
    {:ok, rolls} =
      Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn -> 1 end)

    {:ok, before} = WorldResolver.resolve(c.snapshot, %{}, rolls)
    [first | rest] = rolls
    altered = [Map.put(first, "value", 6) | rest]
    {:ok, after_draft} = WorldResolver.resolve(c.snapshot, %{}, altered)

    assert Map.delete(List.last(before["private_results"]), "sequence") ==
             Map.delete(List.last(after_draft["private_results"]), "sequence")

    assert Enum.drop(after_draft["rolls"], 1) == rest
    assert hd(after_draft["private_results"])["outcome"] == "success"
    assert hd(before["private_results"])["outcome"] == "failure"

    assert {:ok, ^rolls} =
             Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn -> 6 end)
  end

  test "invalid random value rolls back the whole reservation and immutable rows reject rewrites",
       c do
    assert {:error, :invalid_rolls} =
             Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn -> 0 end)

    assert Repo.aggregate(Roll, :count) == 0

    assert {:error, :stale_input} =
             Ticks.record_quest_rolls(c.campaign.id, c.tick.id, Ecto.UUID.generate())

    {:ok, _} =
      Ticks.record_quest_rolls(c.campaign.id, c.tick.id, c.snapshot.revision, fn -> 4 end)

    row = Repo.one!(from r in Roll, limit: 1)

    for statement <- [
          "UPDATE quest_rolls SET value = 6 WHERE id = $1",
          "DELETE FROM quest_rolls WHERE id = $1"
        ] do
      assert_raise Postgrex.Error, fn -> Repo.query!(statement, [row.id], mode: :savepoint) end
    end

    assert Repo.get!(Roll, row.id).value == 4
  end
end
