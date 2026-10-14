defmodule AsyncWorlds.Ticks.PersonalHistoryTest do
  use AsyncWorlds.DataCase, async: false
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Campaigns, Characters, PlayerAccess, Quests, Ticks}
  alias AsyncWorlds.Discord.{DebugSessions, PrivateRetrieval}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Ticks.{PersonalHistory, WorldResolver}

  setup do
    campaign = history_campaign()

    %{
      campaign: campaign,
      guild: campaign.discord_guild_id,
      scope: %{campaign: campaign, discord_user_id: campaign.dm_user_id}
    }
  end

  test "empty history is structured nil and Discord owns empty-state presentation", c do
    {:ok, character} =
      Characters.create_character(c.campaign, c.campaign.dm_user_id, %{
        name: "New",
        discord_user_id: "44004"
      })

    assert {:ok, nil} = PersonalHistory.result(c.guild, "44004")
    assert {:ok, nil} = PersonalHistory.submission(c.guild, "44004")
    assert {:ok, nil} = PersonalHistory.dm_result(c.scope, character.id)
    assert {:ok, nil} = PersonalHistory.dm_submission(c.scope, character.id)
    assert {:ok, "No published personal result yet."} = PrivateRetrieval.result(c.guild, "44004")
    assert {:ok, :no_submission} = PrivateRetrieval.submission(c.guild, "44004")
    assert {:error, :not_found} = PersonalHistory.result(c.guild, "44005")
    assert {:error, :not_found} = PersonalHistory.submission(c.guild, "44005")
  end

  test "returns whitelisted frozen metadata/content, independent of delivery state or later live edits",
       c do
    h = publish_history_quest(c.campaign)
    assert {:ok, result} = PersonalHistory.result(c.guild, "44004")

    assert Enum.sort(Map.keys(result)) == [
             :character_id,
             :content_chunks,
             :published_at,
             :tick_id,
             :tick_number
           ]

    assert result.character_id == h.character.id
    assert result.tick_id == h.tick.id
    assert result.tick_number == 1
    assert %DateTime{} = result.published_at
    assert Enum.join(result.content_chunks, "") =~ "Saved private narration"
    refute Enum.join(result.content_chunks, "") =~ "private_fact"
    assert {:ok, text} = PrivateRetrieval.result(c.guild, "44004")
    assert text == Enum.join(result.content_chunks, "")

    assert {:ok, submission} = PersonalHistory.submission(c.guild, "44004")

    assert submission == %{
             character_id: h.character.id,
             tick_id: h.tick.id,
             tick_number: 1,
             choice_id: "roll",
             choice_label: "roll"
           }

    assert {:ok, text} = PrivateRetrieval.submission(c.guild, "44004")

    assert text ==
             "Tick 1 — Latest choice: roll (closed). Use /quest for your current quest and /result for your approved result."

    Repo.update_all(AsyncWorlds.Deliveries.Delivery, set: [status: :failed])

    {:ok, _} =
      Characters.update_character(c.campaign, c.campaign.dm_user_id, h.character.id, %{
        name: "Renamed"
      })

    definition =
      put_in(
        h.revision.definition,
        ["nodes", Access.at(0), "choices", Access.at(0), "label"],
        "Changed label"
      )

    {:ok, _} =
      Quests.append_revision(c.campaign, c.campaign.dm_user_id, h.revision.quest_id, definition)

    assert {:ok, ^result} = PersonalHistory.result(c.guild, "44004")
    assert {:ok, ^submission} = PersonalHistory.submission(c.guild, "44004")
  end

  test "closed submission is available before approval, while result stays unpublished", c do
    {:ok, character} =
      Characters.create_character(c.campaign, c.campaign.dm_user_id, %{
        name: "Hero",
        discord_user_id: "44004"
      })

    {:ok, revision} =
      Quests.create_quest(
        c.campaign,
        c.campaign.dm_user_id,
        %{content_id: "quest", name: "Quest"},
        AsyncWorlds.QuestFixtures.definition()
      )

    {:ok, _} = Quests.assign(c.campaign, c.campaign.dm_user_id, character.id, revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state(c.guild, "44004")
    {:ok, _} = Submissions.submit(c.guild, "44004", state.identity, "loop")
    assert {:ok, nil} = PersonalHistory.submission(c.guild, "44004")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    assert {:ok, %{choice_label: "loop"}} = PersonalHistory.submission(c.guild, "44004")
    assert {:ok, nil} = PersonalHistory.result(c.guild, "44004")
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    assert {:ok, %{tick_number: 1}} = PersonalHistory.result(c.guild, "44004")

    # A newer draft must not replace the last approved result.
    {:ok, result} = PersonalHistory.result(c.guild, "44004")
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state(c.guild, "44004")
    {:ok, _} = Submissions.submit(c.guild, "44004", state.identity, "finish")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    assert {:ok, ^result} = PersonalHistory.result(c.guild, "44004")

    assert {:ok, %{tick_number: 2, choice_label: "finish"}} =
             PersonalHistory.submission(c.guild, "44004")

    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    assert {:ok, %{tick_number: 2}} = PersonalHistory.result(c.guild, "44004")
  end

  test "ownership changes block inherited history but explicit authorized DM selection remains available",
       c do
    h = publish_history_quest(c.campaign)
    {:ok, result} = PersonalHistory.result(c.guild, "44004")
    {:ok, submission} = PersonalHistory.submission(c.guild, "44004")

    {:ok, _} =
      Characters.update_character(c.campaign, c.campaign.dm_user_id, h.character.id, %{
        discord_user_id: "44005"
      })

    assert {:ok, nil} = PersonalHistory.result(c.guild, "44005")
    assert {:ok, nil} = PersonalHistory.submission(c.guild, "44005")
    assert {:error, :not_found} = PersonalHistory.result(c.guild, "44004")
    assert {:ok, ^result} = PersonalHistory.dm_result(c.scope, to_string(h.character.id))
    assert {:ok, ^submission} = PersonalHistory.dm_submission(c.scope, h.character.id)

    unauthorized = %{c.scope | discord_user_id: "44005"}
    assert {:error, :unauthorized} = PersonalHistory.dm_result(unauthorized, h.character.id)
    assert {:error, :unauthorized} = PersonalHistory.dm_submission(unauthorized, h.character.id)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: c.guild,
        dm_user_id: "22003",
        public_channel_id: "33003"
      })

    assert {:error, :unauthorized} = PersonalHistory.dm_result(c.scope, h.character.id)
    assert {:error, :unauthorized} = PersonalHistory.dm_submission(c.scope, h.character.id)
  end

  test "validated debug personas retain historic access but stale/forged personas cannot", c do
    h = publish_history_quest(c.campaign)

    {:ok, _} =
      Characters.update_character(c.campaign, c.campaign.dm_user_id, h.character.id, %{
        discord_user_id: "44005"
      })

    {:ok, _} = DebugSessions.transition(c.guild, c.campaign.dm_user_id, {:player, h.character.id})
    {:ok, context} = PlayerAccess.context(c.campaign, c.campaign.dm_user_id)
    assert {:ok, %{tick_number: 1}} = PersonalHistory.result(c.guild, context.access)
    assert {:ok, %{choice_label: "roll"}} = PersonalHistory.submission(c.guild, context.access)
    forged = %{context.access | actor_id: "44005"}
    assert {:error, :stale_component} = PersonalHistory.result(c.guild, forged)
    assert {:error, :stale_component} = PersonalHistory.submission(c.guild, forged)
    {:ok, _} = DebugSessions.transition(c.guild, c.campaign.dm_user_id, :off)
    assert {:error, :stale_component} = PersonalHistory.result(c.guild, context.access)
    assert {:error, :stale_component} = PersonalHistory.submission(c.guild, context.access)
  end

  test "DM character selection is campaign-scoped and rejects malformed or oversized IDs", c do
    other = history_campaign("11002")
    h = publish_history_quest(other)

    for id <- [h.character.id, "invalid", nil, -1, "9223372036854775808"] do
      assert {:error, :not_found} = PersonalHistory.dm_result(c.scope, id)
      assert {:error, :not_found} = PersonalHistory.dm_submission(c.scope, id)
    end

    assert {:error, :not_found} = PersonalHistory.result(c.guild, "44004")
    assert {:error, :not_found} = PersonalHistory.submission(c.guild, "44004")
  end

  test "modern retrieval keeps chunk order and excludes DM-copy and other-character messages",
       c do
    {:ok, character} =
      Characters.create_character(c.campaign, c.campaign.dm_user_id, %{
        name: "Hero",
        discord_user_id: "44004"
      })

    owner = %{
      "character_id" => character.id,
      "delivery_audience" => "owner",
      "recipient_id" => "44004",
      "content" => "first"
    }

    messages = [
      owner,
      %{owner | "delivery_audience" => "dm_copy", "content" => "SECRET COPY"},
      %{owner | "character_id" => character.id + 1, "content" => "OTHER"},
      %{owner | "content" => "second"}
    ]

    legacy_publication(c.campaign, 1,
      payload: %{
        "schema_version" => 3,
        "characters" => [%{"id" => character.id, "discord_user_id" => "44004"}],
        "private_results" => [%{"character_id" => character.id}]
      },
      outputs: %{"players" => messages}
    )

    assert {:ok, %{content_chunks: ["first", "second"]}} =
             PersonalHistory.result(c.guild, "44004")

    assert {:ok, "firstsecond"} = PrivateRetrieval.result(c.guild, "44004")
  end

  test "DM-controlled history selects the character primary output, not all output to the DM",
       c do
    {:ok, character} =
      Characters.create_character(c.campaign, c.campaign.dm_user_id, %{name: "Accountless"})

    primary = %{
      "character_id" => character.id,
      "delivery_audience" => "dm_controlled",
      "recipient_id" => c.campaign.dm_user_id,
      "content" => "Primary"
    }

    legacy_publication(c.campaign, 1,
      payload: %{
        "schema_version" => 3,
        "characters" => [%{"id" => character.id, "discord_user_id" => nil}],
        "private_results" => [%{"character_id" => character.id}]
      },
      outputs: %{
        "players" => [
          primary,
          %{primary | "character_id" => character.id + 1, "content" => "Another character"}
        ]
      }
    )

    assert {:ok, %{content_chunks: ["Primary"]}} =
             PersonalHistory.dm_result(c.scope, character.id)

    {:ok, _} = DebugSessions.transition(c.guild, c.campaign.dm_user_id, {:player, character.id})
    {:ok, context} = PlayerAccess.context(c.campaign, c.campaign.dm_user_id)
    assert {:ok, %{content_chunks: ["Primary"]}} = PersonalHistory.result(c.guild, context.access)
  end

  test "legacy recipient-based publications remain supported without exposing unrelated messages",
       c do
    {:ok, character} =
      Characters.create_character(c.campaign, c.campaign.dm_user_id, %{
        name: "Legacy",
        discord_user_id: "44004"
      })

    legacy_publication(c.campaign, 1,
      payload: %{
        "schema_version" => 2,
        "characters" => [%{"id" => character.id, "discord_user_id" => "44004"}],
        "private_results" => [%{"character_id" => character.id}]
      },
      outputs: %{
        "players" => [
          %{"recipient_id" => "44004", "content" => "Legacy one"},
          %{"recipient_id" => "44005", "content" => "Other"},
          %{"recipient_id" => "44004", "content" => "Legacy two"}
        ],
        "dm" => [%{"content" => "Secret"}]
      }
    )

    assert {:ok, %{content_chunks: ["Legacy one", "Legacy two"]}} =
             PersonalHistory.result(c.guild, "44004")

    assert {:ok, nil} = PersonalHistory.submission(c.guild, "44004")
  end
end
