defmodule AsyncWorlds.HistoryFixtures do
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Ticks.{Draft, Publication, Snapshot, Tick, WorldResolver}

  def history_campaign(guild \\ "11001", dm \\ "22002") do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: guild,
        dm_user_id: dm,
        public_channel_id: "33003"
      })

    campaign
  end

  def publish_world(campaign) do
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)
    {:ok, _} = Ticks.publish_tick(campaign.id, tick.id, draft.id)
    tick
  end

  def publish_history_quest(campaign) do
    actor = campaign.dm_user_id

    {:ok, clock} =
      Clocks.create_clock(
        campaign.id,
        %{name: "Frozen secret clock", visibility: :hidden, segments: 4},
        "dm"
      )

    choice =
      rolled()
      |> put_in(["outcomes", "success", "effects"], [
        %{"type" => "clock_delta", "clock_id" => clock.id, "delta" => 2},
        %{"type" => "set_flag", "key" => "private_fact", "flag" => flag()}
      ])

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        actor,
        %{content_id: "history-quest", name: "Original quest"},
        replace_choice(definition(), choice)
      )

    {:ok, character} =
      Characters.create_character(campaign, actor, %{
        name: "Original hero",
        discord_user_id: "44004"
      })

    {:ok, tick} = Ticks.open_tick(campaign.id)

    {:ok, progression} =
      Quests.assign(campaign, actor, character.id, revision.id, reason: "Assignment during tick")

    {:ok, state} = Submissions.player_state(campaign.discord_guild_id, "44004")
    {:ok, _} = Submissions.submit(campaign.discord_guild_id, "44004", state.identity, "roll")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, rolls} = Ticks.record_quest_rolls(campaign.id, tick.id, snapshot.revision, fn -> 6 end)
    {:ok, payload} = WorldResolver.resolve(snapshot, %{}, rolls)
    {:ok, %{draft: initial}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    {:ok, %{draft: draft, edit: edit}} =
      Ticks.edit_draft(
        campaign.id,
        tick.id,
        initial.id,
        %{
          type: "player_narration",
          input_revision: snapshot.revision,
          input: hd(snapshot.data["quest_inputs"]["submissions"]),
          value: "Saved private narration"
        },
        actor,
        "Preserve this correction"
      )

    {:ok, _} = Ticks.publish_tick(campaign.id, tick.id, draft.id)

    %{
      campaign: campaign,
      tick: tick,
      clock: clock,
      character: character,
      revision: revision,
      progression: progression,
      draft: draft,
      initial: initial,
      edit: edit
    }
  end

  # Stored v1 fixture deliberately omits all quest fields and historical character labels.
  def legacy_publication(campaign, number, opts \\ []) do
    tick =
      Repo.insert!(%Tick{
        campaign_id: campaign.id,
        number: number,
        status: :published,
        draft_revision: 1,
        opened_at: DateTime.utc_now(),
        closed_at: DateTime.utc_now(),
        reviewed_at: DateTime.utc_now(),
        published_at: DateTime.utc_now()
      })

    revision = Ecto.UUID.generate()

    Repo.insert!(%Snapshot{
      tick_id: tick.id,
      revision: revision,
      schema_version: 1,
      data: %{"tick_number" => number, "clocks" => []}
    })

    payload = %{
      "schema_version" => 1,
      "world_news" => ["Legacy approved news #{number}"],
      "clocks" => [],
      "log" => [],
      "effects" => []
    }

    payload = Map.merge(payload, Keyword.get(opts, :payload, %{}))

    outputs =
      Keyword.get(opts, :outputs, %{
        "public" => [
          %{
            "recipient_id" => "33003",
            "kind" => "public",
            "content" => "Legacy stored message #{number}"
          }
        ],
        "dm" => []
      })

    draft =
      Repo.insert!(%Draft{
        tick_id: tick.id,
        revision: 1,
        input_revision: revision,
        payload: payload
      })

    Repo.insert!(%Publication{
      tick_id: tick.id,
      draft_id: draft.id,
      payload: payload,
      outputs: outputs
    })

    tick
  end
end
