defmodule AsyncWorlds.Discord.CharacterCommandTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Characters, Quests}
  alias AsyncWorlds.Discord.{Commands, Dispatcher, FakeAdapter, NostrumAdapter}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{
        name: "Rook",
        discord_user_id: "999",
        flags: %{
          "secret" => %{"type" => "string", "value" => "classified", "player_visible" => false},
          "debt" => %{"type" => "integer", "value" => 2, "player_visible" => true}
        }
      })

    {:ok, other} =
      Characters.create_character(campaign, "456", %{name: "Someone else", discord_user_id: "998"})

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Story", content_id: "story"},
        AsyncWorlds.QuestFixtures.definition()
      )

    {:ok, _} =
      Quests.assign(campaign, "456", character.id, revision.id,
        reason: "SECRET Rook audit reason"
      )

    {:ok, _} =
      Quests.assign(campaign, "456", other.id, revision.id, reason: "SECRET other audit reason")

    %{
      campaign: campaign,
      revision: revision,
      character: character,
      other: other,
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp interaction do
    %{
      type: 2,
      id: System.unique_integer([:positive]),
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 999},
      user: %{id: 998},
      token: "test-only",
      data: %{name: "character"}
    }
  end

  test "visible ordinary strings display literal quotes and whitespace without JSON encoding",
       c do
    text = ~s(  The "Captain"  )

    {:ok, _} =
      Characters.set_flag(c.campaign, "456", c.character.id, "title", %{
        "type" => "string",
        "value" => text,
        "player_visible" => true
      })

    {:ok, _} =
      Characters.set_flag(c.campaign, "456", c.character.id, "ready", %{
        "type" => "boolean",
        "value" => false,
        "player_visible" => true
      })

    expected = "Rook\ndebt: 2\nready: false\ntitle: " <> text
    assert {:ok, ^expected} = Dispatcher.handle(interaction(), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, ^expected}}
  end

  test "character uses authenticated member only and replies privately with visible facts", c do
    assert {:ok, "Rook\ndebt: 2" = content} = Dispatcher.handle(interaction(), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, ^content}}
    assert NostrumAdapter.followup_data(content).flags == 64
    refute content =~ "secret"
    refute content =~ "classified"
    refute content =~ "SECRET"
    refute content =~ "Someone else"

    assert {:ok, "Someone else"} =
             Dispatcher.handle(put_in(interaction(), [:member, :user_id], 998), c.opts)

    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, "Someone else"}}
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
    assert {:ok, :character, :player} = Commands.route(%{name: "character"})
  end

  test "disposable two-player offline scenario preserves independent assignments through interventions",
       c do
    alias AsyncWorlds.Quests.{Progression, Submissions}
    alias AsyncWorlds.Ticks
    {:ok, a_state} = Quests.management_state(c.campaign, "456", c.character.id)
    {:ok, b_state} = Quests.management_state(c.campaign, "456", c.other.id)
    a = a_state.selected.progression
    b = b_state.selected.progression
    refute a.id == b.id
    assert a.revision_id == b.revision_id
    {:ok, _} = Ticks.open_tick(c.campaign.id)

    for user <- ["999", "998"] do
      {:ok, state} = Submissions.player_state("123", user)
      {:ok, _} = Submissions.submit("123", user, state.identity, "loop")
    end

    {:ok, moved} =
      Quests.move(c.campaign, "456", a.id, "end",
        reason: "SECRET manual ending",
        expected_progression: a
      )

    assert moved.status == :completed
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "998")
    assert Repo.get!(Progression, b.id) == b

    {:ok, restarted} =
      Quests.assign(c.campaign, "456", c.character.id, c.revision.id, expected_progression: nil)

    {:ok, replaced} =
      Quests.swap(c.campaign, "456", c.character.id, c.revision.id,
        expected_progression: restarted
      )

    {:ok, ended} =
      Quests.end_quest(c.campaign, "456", replaced.id, expected_progression: replaced)

    assert ended.status == :ended
    assert Repo.get!(Progression, b.id) == b
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "998")
    assert {:ok, "Rook\ndebt: 2"} = Dispatcher.handle(interaction(), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, "Rook\ndebt: 2"}}

    assert {:ok, "Someone else"} =
             Dispatcher.handle(put_in(interaction(), [:member, :user_id], 998), c.opts)

    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, "Someone else"}}
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
  end

  test "supplied character IDs and missing/invalid authenticated identity never select another owner",
       c do
    for options <- [
          [%{name: "character_id", type: 4, value: c.other.id}],
          [%{name: "user_id", type: 3, value: "998"}]
        ] do
      forged = put_in(interaction(), [:data, :options], options)
      assert {:error, :unknown_command} = Dispatcher.handle(forged, c.opts)
    end

    for member <- [nil, %{}, %{user_id: "0999"}, %{user_id: "18446744073709551616"}] do
      assert {:error, :unauthorized} =
               Dispatcher.handle(Map.put(interaction(), :member, member), c.opts)
    end

    assert {:error, :not_found} =
             Dispatcher.handle(put_in(interaction(), [:member, :user_id], 997), c.opts)

    assert {:error, :unauthorized} =
             Dispatcher.handle(Map.put(interaction(), :guild_id, 124), c.opts)

    refute_receive {:discord, :send_public, _}
  end
end
