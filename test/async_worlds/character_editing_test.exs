defmodule AsyncWorlds.CharacterEditingTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Ticks}
  alias AsyncWorlds.Characters.{Character, Flags}
  alias AsyncWorlds.Quests.{Progression, Submissions}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, a} =
      Characters.create_character(campaign, "456", %{name: "Rook", discord_user_id: "991"})

    {:ok, b} =
      Characters.create_character(campaign, "456", %{name: "Finch", discord_user_id: "992"})

    %{campaign: campaign, a: a, b: b}
  end

  test "ordinary values retain quotes; native types and persistence boundaries are explicit" do
    parse = fn type, value ->
      Flags.parse(%{
        "key" => "fact",
        "type" => type,
        "value" => value,
        "player_visible" => "false"
      })
    end

    for text <- ["", " plain \"quotes\" ", "日本語", String.duplicate("x", 2000)] do
      assert {:ok, %{"value" => ^text}} = parse.("string", text)
    end

    assert {:ok, %{"value" => false}} = parse.("boolean", "false")
    assert {:ok, %{"value" => -9_007_199_254_740_991}} = parse.("integer", "-9007199254740991")

    for text <- ["2.5", "1e3", "12x", "9007199254740992", "", " 1"] do
      assert {:error, :invalid_flag_integer} = parse.("integer", text)
    end

    for text <- [<<0>>, <<255>>, String.duplicate("é", 1001)] do
      assert {:error, :invalid_flag_string} = parse.("string", text)
    end

    assert {:error, :invalid_flag_value} = parse.("boolean", "yes")

    assert {:error, :invalid_flag_visibility} =
             Flags.parse(%{"key" => "fact", "type" => "string", "value" => "ok"})

    assert {:error, :invalid_flag_key} =
             Flags.parse(%{"key" => <<255>>, "type" => "string", "value" => "ok"})
  end

  test "ABA edits and stale clear reject atomically, including writes bypassing the editor", c do
    {:ok, renamed} =
      Characters.update_character(c.campaign, "456", c.a.id, %{name: "Away"},
        expected_character: c.a
      )

    {:ok, restored} =
      Characters.update_character(c.campaign, "456", c.a.id, %{name: "Rook"},
        expected_character: renamed
      )

    assert restored.state_version == c.a.state_version + 2

    assert {:error, :stale_character} =
             Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "993"},
               expected_character: c.a
             )

    assert {:error, :stale_character} =
             Characters.set_flag(c.campaign, "456", c.a.id, "ready", flag(),
               expected_character: c.a
             )

    assert {:error, :stale_character} =
             Characters.clear_flag(c.campaign, "456", c.a.id, "ready", expected_character: c.a)

    assert Repo.get!(Character, c.a.id) == restored

    Repo.update_all(from(ch in Character, where: ch.id == ^c.a.id),
      set: [flags: %{"ready" => flag()}]
    )

    assert {:error, :stale_character} =
             Characters.clear_flag(c.campaign, "456", c.a.id, "ready",
               expected_character: restored
             )

    assert Repo.get!(Character, c.b.id) == c.b
  end

  test "ownership invalidates only that player's submission; failed uniqueness preserves both",
       c do
    {:ok, revision} =
      Quests.create_quest(
        c.campaign,
        "456",
        %{content_id: "two", name: "Two players"},
        definition()
      )

    {:ok, a_quest} =
      Quests.assign(c.campaign, "456", c.a.id, revision.id, reason: "Private Rook reason")

    {:ok, b_quest} =
      Quests.assign(c.campaign, "456", c.b.id, revision.id, reason: "Private Finch reason")

    {:ok, _} = Ticks.open_tick(c.campaign.id)

    for user <- ["991", "992"] do
      {:ok, state} = Submissions.player_state("123", user)
      {:ok, _} = Submissions.submit("123", user, state.identity, "loop")
    end

    assert {:error, %Ecto.Changeset{}} =
             Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "992"},
               expected_character: c.a
             )

    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")

    {:ok, relinked} =
      Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "993"},
        expected_character: c.a
      )

    assert {:error, :not_found} = Characters.player_character("123", "991")
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "993")
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "992")
    assert Repo.get!(Progression, a_quest.id) == a_quest
    assert Repo.get!(Progression, b_quest.id) == b_quest

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: ""},
        expected_character: relinked
      )

    assert {:error, :not_found} = Characters.player_character("123", "993")
  end

  test "profile, set and clear preserve resolving and review locks", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

    for stage <- [:resolving, :in_review] do
      if stage == :in_review do
        {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
        {:ok, _} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
      end

      assert {:error, :tick_locked} =
               Characters.update_character(c.campaign, "456", c.a.id, %{name: "Locked"},
                 expected_character: c.a
               )

      assert {:error, :tick_locked} =
               Characters.set_flag(c.campaign, "456", c.a.id, "ready", flag(),
                 expected_character: c.a
               )

      assert {:error, :tick_locked} =
               Characters.clear_flag(c.campaign, "456", c.a.id, "ready", expected_character: c.a)

      assert Repo.get!(Character, c.a.id) == c.a
      assert {:ok, ^snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)
    end
  end
end
