defmodule AsyncWorlds.Ticks.QuestReviewPublicationTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Deliveries, Quests, Ticks}
  alias AsyncWorlds.Quests.{Progression, Submissions, Unlock}
  alias AsyncWorlds.Ticks.{Draft, Publication, Roll, WorldResolver}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, clock} =
      Clocks.create_clock(
        campaign.id,
        %{name: "Hidden mechanism", visibility: :hidden, segments: 4},
        "dm"
      )

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

    pairs =
      for user <- ["991", "992"] do
        {:ok, character} =
          Characters.create_character(campaign, "456", %{name: user, discord_user_id: user})

        {:ok, progression} = Quests.assign(campaign, "456", character.id, revision.id)
        {character, progression}
      end

    {character, _} = hd(pairs)

    {:ok, _} =
      Quests.configure_clock_triggers(campaign, "456", clock.id, [
        %{type: :set_flag, character_id: character.id, key: "hidden_trigger", flag: flag()},
        %{type: :unlock_quest, character_id: character.id, quest_id: revision.quest_id}
      ])

    {:ok, tick} = Ticks.open_tick(campaign.id)

    for user <- ["991", "992"] do
      {:ok, state} = Submissions.player_state("123", user)
      {:ok, _} = Submissions.submit("123", user, state.identity, "roll")
    end

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, rolls} = Ticks.record_quest_rolls(campaign.id, tick.id, snapshot.revision, fn -> 1 end)
    {:ok, payload} = WorldResolver.resolve(snapshot, %{}, rolls)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    %{
      campaign: campaign,
      clock: clock,
      revision: revision,
      pairs: pairs,
      tick: tick,
      snapshot: snapshot,
      rolls: rolls,
      draft: draft
    }
  end

  defp op(c, type, value),
    do: %{
      type: type,
      input_revision: c.snapshot.revision,
      input: hd(c.snapshot.data["quest_inputs"]["submissions"]),
      value: value
    }

  defp edit(c, draft, operation, roller \\ fn -> 6 end),
    do:
      Ticks.edit_draft(
        c.campaign.id,
        c.tick.id,
        draft.id,
        operation,
        "456",
        "Reviewed correction",
        roller
      )

  test "selected rerolls audit effective old/new identity, preserve immutable originals and unrelated dice",
       c do
    [first | rest] = c.rolls

    assert {:ok, %{draft: rerolled, edit: audit}} =
             edit(c, c.draft, %{type: "reroll", identity: first["identity"], old_value: 1})

    assert audit.operation == %{
             "type" => "reroll",
             "identity" => first["identity"],
             "old_value" => 1,
             "new_value" => 6
           }

    assert Enum.drop(rerolled.payload["rolls"], 1) == rest
    assert hd(rerolled.payload["private_results"])["outcome"] == "success"
    refute hd(rerolled.payload["private_results"])["critical"]
    assert Enum.all?(Repo.all(Roll), &(&1.value == 1))

    assert {:error, :stale_identity} =
             edit(c, rerolled, %{type: "reroll", identity: first["identity"], old_value: 1}, fn ->
               flunk("stale reroll consumed RNG")
             end)

    assert {:ok, %{draft: again}} =
             edit(c, rerolled, %{type: "reroll", identity: first["identity"], old_value: 6}, fn ->
               4
             end)

    assert hd(again.payload["rolls"])["value"] == 4
    assert Enum.drop(again.payload["rolls"], 1) == rest
    assert {:ok, _} = Ticks.preview_draft(c.campaign.id, c.tick.id, again.id)
  end

  for kind <- [:extra_key, :missing_old_value] do
    @malformed_reroll kind
    test "persisted #{@malformed_reroll} reroll history cannot reach preview or publication", c do
      die = hd(c.rolls)
      review = %{"dice" => %{die["identity"] => 6}}
      assert {:ok, payload} = WorldResolver.resolve(c.snapshot, review, c.rolls)

      assert {:ok, %{draft: next}} =
               Ticks.put_draft(
                 c.campaign.id,
                 c.tick.id,
                 c.snapshot.revision,
                 payload,
                 c.draft.id
               )

      operation = %{
        "type" => "reroll",
        "identity" => die["identity"],
        "old_value" => 999,
        "new_value" => 6
      }

      operation =
        case @malformed_reroll do
          :extra_key -> Map.put(operation, "extra", true)
          :missing_old_value -> Map.delete(operation, "old_value")
        end

      Repo.insert!(%AsyncWorlds.Ticks.ReviewEdit{
        tick_id: c.tick.id,
        previous_draft_id: c.draft.id,
        draft_id: next.id,
        actor_id: "456",
        reason: "Low-level malformed history fixture",
        operation: operation
      })

      assert {:error, :invalid_draft} = Ticks.preview_draft(c.campaign.id, c.tick.id, next.id)
      assert {:error, :invalid_draft} = Ticks.publish_tick(c.campaign.id, c.tick.id, next.id)
      assert Repo.aggregate(Publication, :count) == 0
      assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(c.campaign.id, c.tick.id)

      for {character, progression} <- c.pairs do
        assert Repo.get!(AsyncWorlds.Characters.Character, character.id) == character
        assert Repo.get!(Progression, progression.id) == progression
      end
    end
  end

  test "outcome override cannot fabricate critical, removed effects keep all dice, clear restores",
       c do
    assert {:ok, %{draft: success}} = edit(c, c.draft, op(c, "outcome", "success"))
    result = hd(success.payload["private_results"])
    assert result["outcome"] == "success"
    refute result["critical"]
    assert success.payload["rolls"] == c.rolls
    assert hd(success.payload["clocks"])["completed"]
    assert success.payload["unlocked_quests"] != []
    assert {:ok, %{draft: failure}} = edit(c, success, op(c, "outcome", "failure"))
    assert failure.payload["rolls"] == c.rolls
    assert failure.payload["trigger_results"] == []
    assert failure.payload["unlocked_quests"] == []
    assert hd(failure.payload["characters"])["flags"] == %{}
    assert {:ok, %{draft: restored}} = edit(c, failure, op(c, "outcome", nil))
    assert restored.payload == c.draft.payload
  end

  test "natural reviewed critical is suppressed for forced partial and restored on clear", c do
    [one, two | _] = c.rolls

    {:ok, %{draft: d}} =
      edit(c, c.draft, %{type: "reroll", identity: one["identity"], old_value: 1})

    {:ok, %{draft: d}} = edit(c, d, %{type: "reroll", identity: two["identity"], old_value: 1})
    assert hd(d.payload["private_results"])["critical"]
    {:ok, %{draft: partial}} = edit(c, d, op(c, "outcome", "partial"))
    refute hd(partial.payload["private_results"])["critical"]
    assert hd(partial.payload["characters"])["flags"] == %{}
    assert partial.payload["rolls"] == d.payload["rolls"]
    {:ok, %{draft: restored}} = edit(c, partial, op(c, "outcome", nil))
    assert restored.payload == d.payload
  end

  test "private exact preview, atomic state/unlocks/history/outbox and safe player APIs", c do
    {:ok, %{draft: d}} = edit(c, c.draft, op(c, "outcome", "success"))
    {:ok, %{draft: d}} = edit(c, d, op(c, "player_narration", "Approved private narration"))
    {:ok, preview} = Ticks.preview_draft(c.campaign.id, c.tick.id, d.id)
    assert Enum.map(preview["players"], & &1["recipient_id"]) == ["991", "992"]
    assert hd(preview["players"])["content"] =~ "Approved private narration\nEnding"
    assert List.last(preview["players"])["content"] =~ "Hub\nroll"

    refute Enum.any?(
             preview["players"],
             &(&1["content"] =~ "hidden_trigger" or &1["content"] =~ "Hidden mechanism")
           )

    {:ok, publication_tick} = Ticks.publish_tick(c.campaign.id, c.tick.id, d.id)
    assert publication_tick.status == :published
    {character, progression} = hd(c.pairs)
    assert Repo.get!(Progression, progression.id).status == :completed

    assert Repo.get!(Progression, progression.id).position_version ==
             progression.position_version + 1

    assert Repo.get!(AsyncWorlds.Characters.Character, character.id).flags["hidden_trigger"] ==
             flag()

    assert Repo.aggregate(Unlock, :count) == 1
    assert hd(Clocks.list_clocks(c.campaign.id)).completed
    {:ok, publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)
    assert publication.outputs == preview
    assert publication.payload == d.payload
    messages = for {_, values} <- preview, message <- values, do: message

    deliveries =
      Enum.reject(
        Deliveries.list_deliveries(c.campaign.id),
        &String.ends_with?(&1.key, ":opened")
      )

    assert length(deliveries) == length(messages)

    assert Enum.sort(
             Enum.map(deliveries, &{Atom.to_string(&1.kind), &1.recipient_id, &1.content})
           ) == Enum.sort(Enum.map(messages, &{&1["kind"], &1["recipient_id"], &1["content"]}))

    assert {:error, :already_published} = Ticks.publish_tick(c.campaign.id, c.tick.id, d.id)
    assert {:error, :no_tick} = Submissions.player_state("123", "991")
    assert {:ok, player} = Characters.player_character("123", "991")
    refute Map.has_key?(player.flags, "hidden_trigger")

    for record <- [publication, Repo.get!(Draft, c.draft.id), hd(Repo.all(Roll))] do
      assert_raise Postgrex.Error, fn -> Repo.delete!(record, mode: :savepoint) end
    end

    {:ok, _} = Characters.set_flag(c.campaign, "456", character.id, "later", flag())
    assert {:ok, ^publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)
  end

  test "private outbox conflict rolls back quest state, clocks, unlocks, history, jobs and lifecycle",
       c do
    {:ok, %{draft: d}} = edit(c, c.draft, op(c, "outcome", "success"))

    {:ok, _} =
      Deliveries.enqueue(c.campaign.id, c.tick.id, %{
        key: "tick:#{c.tick.id}:players:991:0",
        kind: :private,
        recipient_id: "991",
        content: "Conflict"
      })

    before =
      {Repo.aggregate(Oban.Job, :count), Deliveries.list_deliveries(c.campaign.id),
       Clocks.list_audits(c.campaign.id)}

    assert {:error, :delivery_conflict} = Ticks.publish_tick(c.campaign.id, c.tick.id, d.id)

    assert before ==
             {Repo.aggregate(Oban.Job, :count), Deliveries.list_deliveries(c.campaign.id),
              Clocks.list_audits(c.campaign.id)}

    for {character, progression} <- c.pairs do
      assert Repo.get!(AsyncWorlds.Characters.Character, character.id) == character
      assert Repo.get!(Progression, progression.id) == progression
    end

    assert Repo.aggregate(Unlock, :count) == 0
    assert Repo.aggregate(Publication, :count) == 0
    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 0
    assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(c.campaign.id, c.tick.id)
    assert Repo.get!(AsyncWorlds.Campaigns.Campaign, c.campaign.id).clock_mutations_locked
    assert Repo.get!(AsyncWorlds.Campaigns.Campaign, c.campaign.id).current_tick_number == 0
  end

  test "invalid/stale targets and authority reject before RNG or draft append", c do
    input = hd(c.snapshot.data["quest_inputs"]["submissions"])

    assert {:error, :invalid_edit} =
             edit(
               c,
               c.draft,
               %{type: "reroll", identity: hd(c.rolls)["identity"], old_value: 1, new_value: 6},
               fn -> flunk("client value accepted") end
             )

    assert {:error, :invalid_rolls} =
             edit(
               c,
               c.draft,
               %{type: "reroll", identity: hd(c.rolls)["identity"], old_value: 1},
               fn -> 7 end
             )

    for operation <- [
          op(c, "outcome", "critical"),
          op(c, "player_narration", " "),
          Map.put(op(c, "outcome", "success"), :input_revision, Ecto.UUID.generate()),
          Map.put(op(c, "outcome", "success"), :input, Map.put(input, "position_version", 99))
        ] do
      assert {:error, _} = edit(c, c.draft, operation)
    end

    assert {:error, :unauthorized} =
             Ticks.edit_draft(
               c.campaign.id,
               c.tick.id,
               c.draft.id,
               op(c, "outcome", "success"),
               "991",
               "reason"
             )

    assert {:error, :invalid_reason} =
             Ticks.edit_draft(
               c.campaign.id,
               c.tick.id,
               c.draft.id,
               op(c, "outcome", "success"),
               "456",
               " "
             )

    assert {:error, :stale_draft} =
             edit(c, %{c.draft | id: Ecto.UUID.generate()}, op(c, "outcome", "success"))

    assert Repo.aggregate(Draft, :count) == 1
  end

  test "database-incompatible review text returns errors without appending or mutating state",
       c do
    text = "hello" <> <<0>> <> "world"
    assert {:error, :invalid_edit} = edit(c, c.draft, op(c, "player_narration", text))
    assert {:error, :invalid_edit} = edit(c, c.draft, %{type: "world_news", text: [text]})

    assert {:error, :invalid_reason} =
             Ticks.edit_draft(
               c.campaign.id,
               c.tick.id,
               c.draft.id,
               op(c, "outcome", "success"),
               "456",
               text
             )

    assert Repo.aggregate(Draft, :count) == 1
    assert Repo.aggregate(AsyncWorlds.Ticks.ReviewEdit, :count) == 0
    assert Repo.aggregate(Publication, :count) == 0

    for {character, progression} <- c.pairs do
      assert Repo.get!(AsyncWorlds.Characters.Character, character.id) == character
      assert Repo.get!(Progression, progression.id) == progression
    end

    assert {:ok, _} = Ticks.preview_draft(c.campaign.id, c.tick.id, c.draft.id)
  end

  test "conditions use final clocks/trigger flags; frozen turn/roll requirements stay pinned",
       c do
    input = hd(c.snapshot.data["quest_inputs"]["submissions"])

    next_choice =
      choice("after", "hub")
      |> Map.put("conditions", [
        %{
          "type" => "character_flag",
          "key" => "hidden_trigger",
          "flag_type" => "boolean",
          "value" => true
        },
        %{
          "type" => "clock_threshold",
          "clock_id" => c.clock.id,
          "operator" => "gte",
          "value" => 4
        }
      ])

    data =
      update_in(c.snapshot.data, ["quest_inputs", "revisions"], fn revisions ->
        Enum.map(revisions, fn revision ->
          update_in(revision, ["definition", "nodes"], fn [hub, ending] ->
            [hub, Map.merge(ending, %{"ending" => false, "choices" => [next_choice]})]
          end)
        end)
      end)

    snapshot = %{c.snapshot | data: data}
    key = AsyncWorlds.Ticks.QuestReview.key(snapshot, input)

    {:ok, success} =
      WorldResolver.resolve(snapshot, %{"outcomes" => %{key => "success"}}, c.rolls)

    assert hd(success["next_nodes"])["projection"]["choices"] == [
             %{"id" => "after", "label" => "after", "enabled" => true}
           ]

    assert success["rolls"] == c.rolls

    assert Enum.map(success["private_results"], & &1["input"]) ==
             snapshot.data["quest_inputs"]["submissions"]

    assert success["schema_version"] == 2

    assert {:error, :invalid_rolls} =
             WorldResolver.resolve(snapshot, %{"outcomes" => %{key => "success"}}, tl(c.rolls))
  end

  test "appended content cannot repin or rewrite approved turn; narration persists then clears",
       c do
    {:ok, %{draft: d}} = edit(c, c.draft, op(c, "player_narration", "Player text"))
    {:ok, %{draft: d}} = edit(c, d, op(c, "outcome", "success"))
    assert hd(d.payload["private_results"])["text"] == "Player text"
    {:ok, %{draft: d}} = edit(c, d, op(c, "player_narration", nil))
    assert hd(d.payload["private_results"])["text"] == "Result"
    {:ok, _} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition())
    assert {:ok, _} = Ticks.publish_tick(c.campaign.id, c.tick.id, d.id)
    {character, progression} = hd(c.pairs)
    assert Repo.get!(Progression, progression.id).revision_id == c.revision.id
    assert {:ok, [_]} = Quests.list_unlocked(c.campaign, "456", character.id)
    {:ok, next_tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: next_snapshot}} = Ticks.close_tick(c.campaign.id, next_tick.id)

    assert next_snapshot.data["quest_unlocks"] == [
             %{"character_id" => character.id, "quest_id" => c.revision.quest_id}
           ]
  end

  test "live ownership, flags, position/revision and routing drift block publication", c do
    {character, progression} = hd(c.pairs)
    {:ok, revision} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition())

    for {record, attrs} <- [
          {character, [discord_user_id: "993"]},
          {character, [flags: %{"changed" => flag()}]},
          {progression, [position_version: 99]},
          {progression, [revision_id: revision.id]},
          {progression, [node_id: "end", status: :completed]},
          {c.campaign, [dm_user_id: "457"]}
        ] do
      Repo.update!(change(record, attrs))

      assert {:error, :stale_live_state} =
               Ticks.publish_tick(c.campaign.id, c.tick.id, c.draft.id)

      Repo.update!(
        change(
          Repo.get!(record.__struct__, record.id),
          Map.take(Map.from_struct(record), Keyword.keys(attrs))
        )
      )
    end

    assert Repo.aggregate(Publication, :count) == 0
  end
end
