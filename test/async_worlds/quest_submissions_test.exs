defmodule AsyncWorlds.QuestSubmissionsTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Ticks}
  alias AsyncWorlds.Quests.{Progression, Submissions}
  alias AsyncWorlds.Ticks.WorldResolver

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

    {:ok, progression} = Quests.assign(campaign, "456", a.id, revision.id)
    {:ok, _} = Quests.assign(campaign, "456", b.id, revision.id)
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, state} = Submissions.player_state("123", "991")

    %{
      campaign: campaign,
      a: a,
      b: b,
      revision: revision,
      progression: progression,
      tick: tick,
      identity: state.identity
    }
  end

  test "submit, replace, clear are private and readiness does not drive closing", c do
    assert {:ok, %{choice_id: "loop"}} = Submissions.submit("123", "991", c.identity, "loop")
    assert {:ok, %{choice_id: "finish"}} = Submissions.submit("123", "991", c.identity, "finish")

    assert {:ok, %{active: 2, submitted: 1, missing: 1}} =
             Submissions.readiness(c.campaign, "456", c.tick.id)

    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "992")
    assert {:ok, %{choice_id: "finish"} = state} = Submissions.player_state("123", "991")
    assert Enum.sort(Map.keys(state)) == [:choice_id, :identity, :open, :quest]
    assert {:error, :unauthorized} = Submissions.list_submissions(c.campaign, "991", c.tick.id)
    assert {:error, :unauthorized} = Submissions.readiness(c.campaign, "991", c.tick.id)

    assert {:ok, [%{"choice_id" => "finish", "character_id" => id}]} =
             Submissions.list_submissions(c.campaign, "456", c.tick.id)

    assert id == c.a.id
    assert {:ok, %{choice_id: nil}} = Submissions.clear("123", "991", c.identity)
    assert {:ok, _} = Submissions.clear("123", "991", c.identity)
    assert {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, c.tick.id)
    assert snapshot.schema_version == 2
    assert snapshot.data["quest_inputs"]["submissions"] == []
    assert {:ok, _} = WorldResolver.resolve(snapshot)
    assert Repo.get!(Progression, c.progression.id).node_id == "hub"
    assert {:ok, %{missing: 2}} = Submissions.readiness(c.campaign, "456", c.tick.id)
  end

  test "foreign, malformed, stale tick/revision/node/instance identities cannot mutate", c do
    assert {:ok, _} = Submissions.submit("123", "991", c.identity, "loop")
    assert {:error, :stale_identity} = Submissions.submit("123", "992", c.identity, "finish")
    assert {:error, :not_found} = Submissions.submit("123", "993", c.identity, "finish")
    assert {:error, :invalid_id} = Submissions.submit("123", nil, c.identity, "finish")

    for identity <- [
          nil,
          %{},
          Map.put(c.identity, :tick_id, 99999),
          Map.put(c.identity, :revision_id, 99999),
          Map.put(c.identity, :node_id, "end"),
          Map.put(c.identity, :progression_id, 99999),
          Map.put(c.identity, :position_version, 2),
          Map.put(c.identity, :tick_id, "1"),
          Map.put(c.identity, :extra, 1)
        ] do
      assert {:error, :stale_identity} = Submissions.submit("123", "991", identity, "finish")
      assert {:error, :stale_identity} = Submissions.clear("123", "991", identity)
    end

    assert {:error, :unavailable_choice} = Submissions.submit("123", "991", c.identity, "unknown")
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")
  end

  test "swap, end, ownership change invalidate; old identities never resurrect", c do
    assert {:ok, _} = Submissions.submit("123", "991", c.identity, "loop")
    {:ok, _} = Quests.swap(c.campaign, "456", c.a.id, c.revision.id)
    assert {:error, :stale_identity} = Submissions.clear("123", "991", c.identity)
    {:ok, state} = Submissions.player_state("123", "991")
    assert state.choice_id == nil
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")
    {:ok, _} = Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "993"})
    assert {:error, :not_found} = Submissions.player_state("123", "991")
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "993")
    {:ok, _} = Submissions.submit("123", "993", state.identity, "loop")
    {:ok, _} = Quests.end_quest(c.campaign, "456", state.identity.progression_id)
    assert {:error, :no_quest} = Submissions.player_state("123", "993")
    assert {:ok, %{submitted: 0, active: 1}} = Submissions.readiness(c.campaign, "456", c.tick.id)
  end

  test "moving away and back changes component version and removes the choice", c do
    d = definition()
    [hub, ending] = d["nodes"]
    other = hub |> Map.put("id", "other") |> Map.put("choices", [choice("back", "hub")])
    d = Map.put(d, "nodes", [hub, other, ending])
    {:ok, r} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, d)
    {:ok, p} = Quests.swap(c.campaign, "456", c.a.id, r.id)
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")
    {:ok, _} = Quests.move(c.campaign, "456", p.id, "other")
    {:ok, _} = Quests.move(c.campaign, "456", p.id, "hub")
    assert {:error, :stale_identity} = Submissions.submit("123", "991", state.identity, "loop")

    assert {:ok, %{choice_id: nil, identity: %{position_version: 3}}} =
             Submissions.player_state("123", "991")
  end

  test "flag and clock eligibility are checked on submit, clear, counts and close", c do
    {:ok, clock} = Clocks.create_clock(c.campaign.id, %{name: "Gate", segments: 4}, "dm")

    gated =
      choice("gate", "end")
      |> Map.put("conditions", [
        %{
          "type" => "character_flag",
          "key" => "secret",
          "flag_type" => "boolean",
          "value" => true
        },
        %{"type" => "clock_threshold", "clock_id" => clock.id, "operator" => "gte", "value" => 1}
      ])

    {:ok, r} =
      Quests.append_revision(
        c.campaign,
        "456",
        c.revision.quest_id,
        replace_choice(definition(), gated)
      )

    {:ok, _} = Quests.swap(c.campaign, "456", c.a.id, r.id)
    {:ok, state} = Submissions.player_state("123", "991")

    assert {:error, :unavailable_choice} =
             Submissions.submit("123", "991", state.identity, "gate")

    {:ok, _} = Characters.set_flag(c.campaign, "456", c.a.id, "secret", flag())

    assert {:error, :unavailable_choice} =
             Submissions.submit("123", "991", state.identity, "gate")

    {:ok, _} = Clocks.adjust_clock(c.campaign.id, clock.id, 1, "dm")
    assert {:ok, _} = Submissions.submit("123", "991", state.identity, "gate")
    {:ok, _} = Characters.clear_flag(c.campaign, "456", c.a.id, "secret")
    assert {:ok, %{submitted: 0}} = Submissions.readiness(c.campaign, "456", c.tick.id)
    assert {:error, :unavailable_choice} = Submissions.clear("123", "991", state.identity)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, c.tick.id)
    inputs = snapshot.data["quest_inputs"]
    assert inputs["submissions"] == []

    assert inputs["invalidations"] == [
             %{"character_id" => c.a.id, "reason" => "stale_or_ineligible"}
           ]

    assert {:ok, _} = WorldResolver.resolve(snapshot)
    assert Repo.get!(Progression, c.progression.id).status == :ended
  end

  test "close freezes once, late writes fail and interventions lock while content remains editable",
       c do
    {:ok, _} = Submissions.submit("123", "991", c.identity, "loop")
    {:ok, _} = Characters.set_flag(c.campaign, "456", c.a.id, "secret", flag())
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, c.tick.id)
    assert {:error, :quest_executor_required} = WorldResolver.resolve(snapshot)
    assert {:error, :tick_closed} = Submissions.submit("123", "991", c.identity, "finish")
    assert {:error, :tick_closed} = Submissions.clear("123", "991", c.identity)
    assert {:error, :tick_locked} = Quests.move(c.campaign, "456", c.progression.id, "end")
    assert {:error, :tick_locked} = Quests.end_quest(c.campaign, "456", c.progression.id)
    assert {:error, :tick_locked} = Quests.swap(c.campaign, "456", c.a.id, c.revision.id)
    assert {:error, :tick_locked} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assert {:error, :tick_locked} = Characters.clear_flag(c.campaign, "456", c.a.id, "secret")

    assert {:error, :tick_locked} =
             Characters.set_flag(c.campaign, "456", c.a.id, "secret", flag(false))

    assert {:error, :tick_locked} =
             Characters.update_character(c.campaign, "456", c.a.id, %{name: "Changed"})

    assert {:error, :tick_locked} =
             Characters.create_character(c.campaign, "456", %{name: "C", discord_user_id: "993"})

    assert {:ok, _} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition())
    assert {:ok, %{snapshot: ^snapshot}} = Ticks.close_tick(c.campaign.id, c.tick.id)
    assert length(snapshot.data["quest_inputs"]["revisions"]) == 1
    assert hd(snapshot.data["quest_inputs"]["characters"])["flags"] == %{"secret" => flag()}
    assert hd(snapshot.data["quest_inputs"]["submissions"])["choice_id"] == "loop"

    assert {:ok, %{active: 2, submitted: 1, missing: 1}} =
             Submissions.readiness(c.campaign, "456", c.tick.id)
  end

  test "foreign campaigns and refreshed DM authority are checked at every boundary", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, _} = Characters.create_character(other, "457", %{name: "Other", discord_user_id: "991"})
    {:ok, tick} = Ticks.open_tick(other.id)
    assert {:error, :stale_identity} = Submissions.submit("124", "991", c.identity, "loop")

    assert {:error, :stale_identity} =
             Submissions.clear("123", "991", %{c.identity | tick_id: tick.id})

    assert {:error, :not_found} = Submissions.list_submissions(c.campaign, "456", tick.id)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "458",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = Submissions.readiness(c.campaign, "456", c.tick.id)
    assert {:ok, %{active: 2}} = Submissions.readiness(c.campaign, "458", c.tick.id)
  end

  test "v2 contract validates references and rejects malformed inputs; v1 remains readable", c do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, c.tick.id)
    assert {:ok, _} = WorldResolver.resolve(snapshot)
    inputs = snapshot.data["quest_inputs"]
    [first | rest] = inputs["progressions"]

    variants = [
      Map.delete(inputs, "revisions"),
      Map.put(inputs, "characters", []),
      Map.put(inputs, "progressions", [Map.put(first, "revision_id", 99999) | rest]),
      Map.put(inputs, "progressions", [Map.put(first, "node_id", "unknown") | rest]),
      Map.put(inputs, "characters", inputs["characters"] ++ inputs["characters"])
    ]

    for invalid <- variants do
      assert {:error, :invalid_snapshot} =
               WorldResolver.resolve(%{
                 snapshot
                 | data: Map.put(snapshot.data, "quest_inputs", invalid)
               })
    end

    v1 = %{snapshot | schema_version: 1, data: Map.delete(snapshot.data, "quest_inputs")}
    assert {:ok, _} = WorldResolver.resolve(v1)

    assert {:error, :invalid_snapshot} =
             WorldResolver.resolve(%{snapshot | data: Map.put(snapshot.data, "clocks", [nil])})
  end

  test "new authored revisions cannot stale a world-only publication", c do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, c.tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, c.tick.id, snapshot.revision, payload)
    {:ok, _} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition())
    assert {:ok, _} = Ticks.publish_tick(c.campaign.id, c.tick.id, draft.id)
    assert Repo.get!(Progression, c.progression.id) == c.progression
    assert {:ok, _} = Characters.update_character(c.campaign, "456", c.a.id, %{name: "Unlocked"})
  end
end
