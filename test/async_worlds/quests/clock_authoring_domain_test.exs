defmodule AsyncWorlds.Quests.ClockAuthoringDomainTest do
  use AsyncWorlds.DataCase
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks}

  alias AsyncWorlds.Quests.{
    Authoring,
    ConditionAuthoring,
    Definition,
    FrozenInputs,
    Submissions,
    WorkingCopy
  }

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, clock} = Clocks.create_clock(campaign.id, %{name: "Gate", segments: 8}, "dm")
    {:ok, foreign_clock} = Clocks.create_clock(foreign.id, %{name: "Foreign", segments: 4}, "dm")
    %{campaign: campaign, foreign: foreign, clock: clock, foreign_clock: foreign_clock}
  end

  defp gate(id, op, value),
    do: %{"type" => "clock_threshold", "clock_id" => id, "operator" => op, "value" => value}

  defp attrs(work), do: Map.take(work, [:name, :content_id, :definition])

  defp draft(c, conditions, effects \\ []) do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    node = hd(work.definition["nodes"])

    choice =
      Authoring.new_choice()
      |> Map.put("label", "Act")
      |> Map.put("conditions", conditions)
      |> put_in(["outcomes", "fixed"], %{
        "text" => "Acted",
        "next_node" => node["id"],
        "effects" => effects
      })

    %{
      work
      | name: "Gate",
        content_id: "gate_#{work.id}",
        definition:
          put_in(work.definition, ["nodes", Access.at(0)], %{
            node
            | "text" => "Hub",
              "choices" => [choice]
          })
    }
  end

  test "both comparisons accept inclusive 0 and current size boundaries; invalid IDs operators thresholds and deltas reject atomically",
       c do
    for op <- ~w(gte lte), threshold <- [0, 8] do
      work = draft(c, [gate(c.clock.id, op, threshold)])

      assert {:ok, _} =
               Quests.release_working_copy(c.campaign, "456", work.id, work.version, attrs(work))
    end

    for invalid <- [
          gate(c.foreign_clock.id, "gte", 0),
          gate(999_999, "gte", 0),
          gate(c.clock.id, "eq", 0),
          gate(c.clock.id, "gte", -1),
          gate(c.clock.id, "lte", 9),
          gate(c.clock.id, "gte", 1.5),
          gate(c.clock.id, "gte", "1")
        ] do
      # Non-projectable imported content is seeded rather than bypassing safe_edit?.
      definition =
        replace_choice(definition(), Map.put(choice("act", "hub"), "conditions", [invalid]))

      work =
        Repo.insert!(%WorkingCopy{
          campaign_id: c.campaign.id,
          name: "Invalid",
          content_id: "bad_#{Ecto.UUID.generate()}",
          definition: definition,
          source_definition: definition
        })

      assert {:error, {:validation, _}} =
               Quests.release_working_copy(c.campaign, "456", work.id, work.version, attrs(work))

      assert Repo.get!(WorkingCopy, work.id) == work
    end

    for {id, delta} <- [
          {c.foreign_clock.id, 1},
          {999_999, 1},
          {c.clock.id, "1.5"},
          {c.clock.id, "oops"}
        ] do
      work = draft(c, [], [%{"type" => "clock_delta", "clock_id" => id, "delta" => delta}])

      assert {:error, {:validation, _}} =
               Quests.release_working_copy(c.campaign, "456", work.id, work.version, attrs(work))

      assert Repo.get!(WorkingCopy, work.id).version == work.version
    end
  end

  test "resizing revalidates working copies but does not rewrite pinned definitions or frozen thresholds",
       c do
    work =
      draft(c, [gate(c.clock.id, "lte", 8)], [
        %{"type" => "clock_delta", "clock_id" => c.clock.id, "delta" => -99}
      ])

    {:ok, %{draft: saved, revision: revision}} =
      Quests.release_working_copy(c.campaign, "456", work.id, work.version, attrs(work))

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, progression} = Quests.assign(c.campaign, "456", character.id, revision.id)
    {:ok, smaller} = Clocks.edit_clock(c.campaign.id, c.clock.id, %{segments: 4}, "dm:resize")
    {:ok, reopened} = Quests.create_working_copy(c.campaign, "456", revision.id)
    assert reopened.definition == revision.definition

    assert {:error, {:validation, errors}} =
             Quests.release_working_copy(
               c.campaign,
               "456",
               reopened.id,
               reopened.version,
               attrs(reopened)
             )

    assert Enum.any?(errors, fn {path, _} -> String.ends_with?(path, ".value") end)
    assert Repo.get!(WorkingCopy, saved.id).definition == revision.definition
    assert Repo.get!(Quests.Progression, progression.id).revision_id == revision.id
    refute Definition.valid?(revision.definition, %{smaller.id => smaller})
    assert Definition.valid?(revision.definition, %{smaller.id => smaller}, :frozen)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state("123", "991")
    assert hd(state.quest.choices).enabled
    choice_id = hd(hd(revision.definition["nodes"])["choices"])["id"]
    {:ok, _} = Submissions.submit("123", "991", state.identity, choice_id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

    assert FrozenInputs.valid?(
             snapshot.data["quest_inputs"],
             snapshot.data["clocks"],
             snapshot.data["schema_version"]
           )

    assert {:ok, payload} = Ticks.WorldResolver.resolve(snapshot)
    assert hd(payload["clocks"])["filled"] == 0
    assert {:ok, ^revision} = Quests.get_revision(c.campaign, "456", revision.id)
    assert Repo.get!(Ticks.Snapshot, snapshot.id) == snapshot
  end

  test "trusted stale campaign structs cannot grant revoked actors access or cross campaign edits",
       c do
    work = draft(c, [gate(c.clock.id, "gte", 0)])

    assert {:error, :not_found} =
             Quests.release_working_copy(c.foreign, "457", work.id, work.version, attrs(work))

    assert {:error, :unauthorized} =
             Quests.save_working_copy(
               %{c.campaign | dm_user_id: "999"},
               "999",
               work.id,
               work.version,
               attrs(work)
             )

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "999",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} =
             Quests.release_working_copy(c.campaign, "456", work.id, work.version, attrs(work))

    assert Repo.get!(WorkingCopy, work.id).version == work.version
  end

  test "unsupported clock fields survive form roundtrips and cannot be removed or converted into editable gates",
       c do
    opaque = Map.put(gate(c.clock.id, "gte", 2), "future", %{"x" => 1})
    refute ConditionAuthoring.editable?(opaque)
    assert ConditionAuthoring.restructure([opaque], "remove", 0) == [opaque]
    work = draft(c, [])

    d =
      put_in(work.definition, ["nodes", Access.at(0), "choices", Access.at(0), "conditions"], [
        opaque
      ])

    imported = %{work | definition: d}
    applied = Authoring.apply_form(imported, %{"node_0_choice_0_condition_0_value" => "0"})
    assert applied.definition == imported.definition
    assert Authoring.safe_edit?(d, applied.definition)
    refute Authoring.safe_edit?(d, work.definition)
  end
end
