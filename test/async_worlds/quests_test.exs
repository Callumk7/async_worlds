defmodule AsyncWorlds.QuestsTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.{Progression, Revision, Rules}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, a} = Characters.create_character(campaign, "456", %{name: "A", discord_user_id: "991"})
    {:ok, b} = Characters.create_character(campaign, "456", %{name: "B", discord_user_id: "992"})

    {:ok, foreign} =
      Characters.create_character(other, "457", %{name: "Foreign", discord_user_id: "991"})

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "quest", name: "Quest"}, definition())

    {:ok, foreign_revision} =
      Quests.create_quest(other, "457", %{content_id: "quest", name: "Foreign"}, definition())

    %{
      campaign: campaign,
      other: other,
      a: a,
      b: b,
      foreign: foreign,
      revision: revision,
      foreign_revision: foreign_revision
    }
  end

  test "persisted independent assignments, cycles, endings and one active constraint", c do
    assert {:ok, a} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assert {:ok, b} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
    assert {:error, :active_quest} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assert {:ok, ^a} = Quests.move(c.campaign, "456", a.id, "hub")
    assert {:error, :invalid_node} = Quests.move(c.campaign, "456", a.id, "foreign")
    assert {:ok, finished} = Quests.move(c.campaign, "456", a.id, "end")
    assert finished.status == :completed
    assert {:ok, ^b} = Quests.get_progression(c.campaign, "456", b.id)
    assert {:error, :not_active} = Quests.move(c.campaign, "456", a.id, "hub")
    assert {:ok, %{choices: [], completed: true}} = Quests.player_quest("123", "991")
    assert {:ok, %{choices: [_, _], completed: false}} = Quests.player_quest("123", "992")
    assert {:ok, replacement} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assert {:ok, ended} = Quests.end_quest(c.campaign, "456", replacement.id)
    assert ended.status == :ended
    assert {:error, :not_active} = Quests.end_quest(c.campaign, "456", ended.id)
    assert {:ok, swapped} = Quests.swap(c.campaign, "456", c.b.id, c.revision.id)
    assert swapped.id != b.id
    assert Repo.get!(Progression, b.id).status == :ended
  end

  test "actual frozen assignments can traverse with the pure helper without player persistence",
       c do
    {:ok, a} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, b} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
    sa = %{node_id: a.node_id, status: a.status, flags: c.a.flags, clocks: %{}}
    sb = %{node_id: b.node_id, status: b.status, flags: c.b.flags, clocks: %{}}
    assert {:ok, sa, _} = Rules.transition(c.revision.definition, sa, "loop")
    assert sa.flags == %{"secret" => flag()}
    assert {:ok, sb, _} = Rules.transition(c.revision.definition, sb, "finish")
    assert sb.status == :completed and sa.status == :active
    assert {:ok, sa, _} = Rules.transition(c.revision.definition, sa, "finish")
    assert sa.flags == %{} and sa.status == :completed
    # Resolution is not publication. No helper is allowed to mutate player state.
    assert Repo.get!(Progression, a.id) == a
    assert Repo.get!(Progression, b.id) == b
    assert {:ok, %{flags: %{}}} = Characters.player_character("123", "991")
  end

  test "immutable revisions, stable IDs and frozen copies survive authoring updates", c do
    {:ok, progression} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, frozen} = Quests.freeze_definitions(c.campaign, "456")
    [hub, ending] = definition()["nodes"]
    changed = put_in(definition()["nodes"], [Map.put(hub, "text", "Changed"), ending])
    {:ok, next} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, changed)
    assert next.number == 2 and next.quest_id == c.revision.quest_id

    assert frozen == [
             %{
               "revision_id" => c.revision.id,
               "quest_id" => c.revision.quest_id,
               "number" => 1,
               "definition" => definition()
             }
           ]

    assert Repo.get!(Revision, c.revision.id) == c.revision
    assert Repo.get!(Progression, progression.id).revision_id == c.revision.id
    assert {:ok, %{text: "Hub"}} = Quests.player_quest("123", "991")
    assert {:ok, _} = Quests.swap(c.campaign, "456", c.a.id, next.id)
    assert {:ok, %{text: "Changed"}} = Quests.player_quest("123", "991")

    assert_db_reject("UPDATE quest_revisions SET definition = '{}' WHERE id = $1", [c.revision.id])

    assert_db_reject("DELETE FROM quest_revisions WHERE id = $1", [c.revision.id])

    assert_db_reject("UPDATE quest_revision_nodes SET node_id = 'other' WHERE revision_id = $1", [
      c.revision.id
    ])
  end

  test "foreign/missing ownership references and malformed content leave database unchanged", c do
    before = Repo.aggregate(Revision, :count)

    for id <- [c.foreign_revision.quest_id, 999_999, "bad", nil] do
      assert {:error, :not_found} = Quests.append_revision(c.campaign, "456", id, definition())
    end

    for character <- [c.foreign.id, 999_999, "bad"],
        do:
          assert(
            {:error, :not_found} = Quests.assign(c.campaign, "456", character, c.revision.id)
          )

    for revision <- [c.foreign_revision.id, 999_999, "bad"],
        do: assert({:error, :not_found} = Quests.assign(c.campaign, "456", c.a.id, revision))

    assert {:ok, foreign} = Quests.assign(c.other, "457", c.foreign.id, c.foreign_revision.id)
    assert {:error, :not_found} = Quests.move(c.campaign, "456", foreign.id, "end")
    assert {:error, :not_found} = Quests.end_quest(c.campaign, "456", foreign.id)
    assert {:error, :not_found} = Quests.get_progression(c.campaign, "456", foreign.id)

    for bad <- [
          %{},
          Map.put(definition(), "start_node", "missing"),
          replace_choice(definition(), Map.put(rolled(), "dice", 4))
        ] do
      assert {:error, :invalid_definition} =
               Quests.append_revision(c.campaign, "456", c.revision.quest_id, bad)

      assert {:error, :invalid_definition} =
               Quests.create_quest(c.campaign, "456", %{content_id: "rejected", name: "No"}, bad)
    end

    assert Repo.aggregate(Revision, :count) == before
    assert Repo.get!(Progression, foreign.id) == foreign
    {:ok, active} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assert {:error, :not_found} = Quests.swap(c.campaign, "456", c.a.id, c.foreign_revision.id)
    assert Repo.get!(Progression, active.id) == active

    assert_db_reject(
      "INSERT INTO quest_progressions (campaign_id, character_id, revision_id, node_id, status) VALUES ($1,$2,$3,'hub','active')",
      [c.campaign.id, c.a.id, c.revision.id]
    )

    assert_db_reject(
      "INSERT INTO quest_progressions (campaign_id, character_id, revision_id, node_id, status) VALUES ($1,$2,$3,'hub','active')",
      [c.campaign.id, c.b.id, c.foreign_revision.id]
    )

    assert_db_reject(
      "INSERT INTO quest_progressions (campaign_id, character_id, revision_id, node_id, status) VALUES ($1,$2,$3,'missing','active')",
      [c.campaign.id, c.b.id, c.revision.id]
    )

    assert_db_reject(
      "INSERT INTO quest_progressions (campaign_id, character_id, revision_id, node_id, status) VALUES ($1,$2,$3,'hub','invalid')",
      [c.campaign.id, c.b.id, c.revision.id]
    )
  end

  test "fresh DM/player authorization, no player mutation and scoped safe projections", c do
    {:ok, active} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)

    for user <- ["991", "457", "999"] do
      assert {:error, :unauthorized} = Quests.assign(c.campaign, user, c.b.id, c.revision.id)
      assert {:error, :unauthorized} = Quests.move(c.campaign, user, active.id, "end")
      assert {:error, :unauthorized} = Quests.end_quest(c.campaign, user, active.id)
      assert {:error, :unauthorized} = Quests.swap(c.campaign, user, c.a.id, c.revision.id)

      assert {:error, :unauthorized} =
               Quests.append_revision(c.campaign, user, c.revision.quest_id, definition())

      assert {:error, :unauthorized} = Quests.get_revision(c.campaign, user, c.revision.id)
      assert {:error, :unauthorized} = Quests.freeze_definitions(c.campaign, user)
    end

    for id <- [nil, "0", "bad", 1.0] do
      assert {:error, :invalid_id} = Quests.player_quest("123", id)
      assert {:error, :invalid_id} = Quests.assign(c.campaign, id, c.b.id, c.revision.id)
    end

    assert {:error, :not_found} = Quests.player_quest("123", "999")
    assert {:error, :no_quest} = Quests.player_quest("124", "991")

    assert {:ok, _} =
             Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "993"})

    assert {:error, :not_found} = Quests.player_quest("123", "991")
    assert {:ok, %{text: "Hub", choices: choices} = safe} = Quests.player_quest("123", "993")
    assert Enum.map(choices, & &1.id) == ["loop", "finish"]
    assert Map.keys(safe) |> Enum.sort() == [:choices, :completed, :text]

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "458",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = Quests.move(c.campaign, "456", active.id, "end")
    assert {:ok, ^active} = Quests.get_progression(c.campaign, "458", active.id)
    assert Repo.get!(Progression, active.id) == active
  end

  test "clock conditions/effects reference only same-campaign clocks and copy typed effects", c do
    {:ok, clock} =
      Clocks.create_clock(
        c.campaign.id,
        %{name: "Secret", segments: 4, visibility: :hidden},
        "dm"
      )

    {:ok, foreign} = Clocks.create_clock(c.other.id, %{name: "Foreign", segments: 4}, "dm")

    for id <- [foreign.id, 999_999] do
      for ch <- [
            Map.put(choice("c", "hub"), "conditions", [
              %{"type" => "clock_threshold", "clock_id" => id, "operator" => "gte", "value" => 1}
            ]),
            choice("c", "hub", [%{"type" => "clock_delta", "clock_id" => id, "delta" => 1}])
          ] do
        assert {:error, :invalid_definition} =
                 Quests.append_revision(
                   c.campaign,
                   "456",
                   c.revision.quest_id,
                   replace_choice(definition(), ch)
                 )
      end
    end

    condition = %{
      "type" => "clock_threshold",
      "clock_id" => clock.id,
      "operator" => "gte",
      "value" => 4
    }

    ch = Map.put(choice("disabled", "hub"), "conditions", [condition])
    d = replace_choice(definition(), ch)
    {:ok, revision} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, d)
    {:ok, _} = Quests.assign(c.campaign, "456", c.a.id, revision.id)

    assert {:ok, %{choices: [%{enabled: false, hint: "Not available right now."}]}} =
             Quests.player_quest("123", "991")

    hidden = Map.put(ch, "eligibility", "hidden")

    {:ok, revision} =
      Quests.append_revision(
        c.campaign,
        "456",
        c.revision.quest_id,
        replace_choice(definition(), hidden)
      )

    {:ok, _} = Quests.swap(c.campaign, "456", c.a.id, revision.id)
    assert {:ok, %{choices: []}} = Quests.player_quest("123", "991")
  end

  test "ending start immediately completes, requires no unusable choice and permits a new assignment",
       c do
    {:ok, revision} =
      Quests.append_revision(
        c.campaign,
        "456",
        c.revision.quest_id,
        Map.put(definition(), "start_node", "end")
      )

    {:ok, progression} = Quests.assign(c.campaign, "456", c.a.id, revision.id)
    assert progression.status == :completed
    assert {:ok, %{choices: [], completed: true}} = Quests.player_quest("123", "991")
    assert {:ok, _} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
  end

  test "typed dependent clock triggers validate targets, freeze payload and do not silently world-publish",
       c do
    {:ok, clock} = Clocks.create_clock(c.campaign.id, %{name: "Trigger", segments: 4}, "dm")

    triggers = [
      %{type: :set_flag, character_id: c.a.id, key: "secret", flag: flag()},
      %{type: :unlock_quest, character_id: c.b.id, quest_id: c.revision.quest_id}
    ]

    assert {:error, :unauthorized} =
             Quests.configure_clock_triggers(c.campaign, "991", clock.id, triggers)

    assert {:ok, updated} = Quests.configure_clock_triggers(c.campaign, "456", clock.id, triggers)
    assert Enum.map(updated.triggers, & &1.type) == [:set_flag, :unlock_quest]
    assert AsyncWorlds.Clocks.Trigger.snapshot(hd(updated.triggers)).flag == flag()

    for invalid <- [
          %{type: :set_flag, character_id: c.foreign.id, key: "secret", flag: flag()},
          %{type: :set_flag, character_id: 999_999, key: "secret", flag: flag()},
          %{type: :set_flag, character_id: c.a.id, key: "Bad", flag: flag()},
          %{
            type: :set_flag,
            character_id: c.a.id,
            key: "secret",
            flag: %{"type" => "boolean", "value" => true}
          },
          %{
            type: :set_flag,
            character_id: c.a.id,
            key: "secret",
            flag: flag(),
            quest_id: c.revision.quest_id
          },
          %{type: :unlock_quest, character_id: c.a.id, quest_id: c.foreign_revision.quest_id},
          %{type: :unlock_quest, character_id: c.a.id, quest_id: 999_999},
          %{type: :unlock_quest, character_id: c.a.id},
          %{type: :unlock_quest, character_id: c.a.id, quest_id: c.revision.quest_id, extra: true}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Quests.configure_clock_triggers(c.campaign, "456", clock.id, [invalid])

      assert Clocks.list_clocks(c.campaign.id) == [updated]
    end

    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    assert {:error, :quest_executor_required} = Ticks.close_tick(c.campaign.id, tick.id)
    assert {:ok, %{status: :open}} = Ticks.fetch_tick(c.campaign.id, tick.id)
    assert {:error, :not_closed} = Ticks.fetch_snapshot(c.campaign.id, tick.id)

    assert {:ok, _} =
             Quests.configure_clock_triggers(c.campaign, "456", clock.id, [
               %{type: :world_news, text: "News"}
             ])

    assert {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
  end

  defp assert_db_reject(sql, params) do
    assert_raise Postgrex.Error, fn -> Repo.query!(sql, params, mode: :savepoint) end
  end
end
