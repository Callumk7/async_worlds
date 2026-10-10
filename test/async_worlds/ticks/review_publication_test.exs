defmodule AsyncWorlds.Ticks.ReviewPublicationTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Clocks, Deliveries, Ticks}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Ticks.{Draft, Publication, ReviewEdit, Tick, WorldResolver}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, target} =
      Clocks.create_clock(
        campaign.id,
        %{
          name: "Known target",
          segments: 6,
          filled: 2,
          paused: true,
          visibility: :known
        },
        "dm"
      )

    {:ok, source} =
      Clocks.create_clock(
        campaign.id,
        %{
          name: "Secret source",
          segments: 4,
          filled: 2,
          background_rate: 1,
          visibility: :hidden,
          triggers: [
            %{type: :start_clock, clock_id: target.id},
            %{type: :world_news, text: "The gate opens"},
            %{type: :notify_dm, text: "Secret notification"}
          ]
        },
        "dm"
      )

    {:ok, public} = Clocks.create_clock(campaign.id, %{name: "Public clock", segments: 4}, "dm")
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    %{
      campaign: campaign,
      tick: tick,
      snapshot: snapshot,
      draft: draft,
      source: source,
      target: target,
      public: public
    }
  end

  defp edit(context, draft, operation) do
    Ticks.edit_draft(
      context.campaign.id,
      context.tick.id,
      draft.id,
      operation,
      "456",
      "DM correction"
    )
  end

  test "edits append revisions, recompute triggers, preview exactly, and publish once", c do
    assert {:ok, %{draft: adjusted, edit: audit}} =
             edit(c, c.draft, %{type: "clock_delta", clock_id: c.source.id, delta: 2})

    assert adjusted.revision == 2
    assert audit.previous_draft_id == c.draft.id
    assert audit.actor_id == "456"
    assert adjusted.payload["world_news"] == ["The gate opens"]
    target = Enum.find(adjusted.payload["clocks"], &(&1["id"] == c.target.id))
    refute target["paused"]
    assert Repo.get!(Clock, c.source.id).filled == 2
    assert Repo.get!(Clock, c.target.id).paused

    assert {:ok, %{draft: narrated}} =
             edit(c, adjusted, %{type: "world_news", text: ["Approved narration"]})

    assert narrated.payload["world_news"] == ["Approved narration"]
    assert narrated.payload["trigger_results"] == adjusted.payload["trigger_results"]
    assert {:ok, preview} = Ticks.preview_draft(c.campaign.id, c.tick.id, narrated.id)
    public_content = Enum.map_join(preview["public"], "", & &1["content"])
    assert public_content =~ "Approved narration"
    assert public_content =~ "Known target"
    assert public_content =~ "Public clock: 0/4"
    refute public_content =~ "2/6"
    refute public_content =~ "Secret"
    assert Enum.map_join(preview["dm"], "", & &1["content"]) =~ "Secret notification"

    assert {:error, :stale_draft} = Ticks.publish_tick(c.campaign.id, c.tick.id, adjusted.id)

    assert {:ok, %{status: :published}} =
             Ticks.publish_tick(c.campaign.id, c.tick.id, narrated.id)

    assert Repo.get!(Clock, c.source.id).completed
    assert Repo.get!(Clock, c.source.id).filled == 4
    refute Repo.get!(Clock, c.target.id).paused
    assert {:ok, publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)
    assert publication.payload == narrated.payload
    assert publication.outputs == preview
    deliveries = Deliveries.list_deliveries(c.campaign.id)
    assert length(deliveries) == 2

    assert Enum.sort(Enum.map(deliveries, & &1.content)) ==
             Enum.sort(for {_, messages} <- preview, message <- messages, do: message["content"])

    assert Repo.get!(Campaign, c.campaign.id).current_tick_number == 1
    refute Repo.get!(Campaign, c.campaign.id).clock_mutations_locked

    assert {:error, :already_published} =
             Ticks.publish_tick(c.campaign.id, c.tick.id, narrated.id)

    assert {:error, {:invalid_transition, :published, :edit_draft}} =
             edit(c, narrated, %{type: "world_news", text: []})

    assert length(Deliveries.list_deliveries(c.campaign.id)) == 2
    assert {:ok, [_, _]} = Ticks.list_review_edits(c.campaign.id, c.tick.id)
    assert Repo.get!(Draft, c.draft.id).payload == c.draft.payload

    assert Enum.any?(
             Clocks.list_audits(c.campaign.id),
             &(&1.source == "review:tick:#{c.tick.number}:clock:#{c.source.id}")
           )
  end

  test "upstream changes remove downstream consequences and clear restores frozen rates", c do
    assert {:ok, %{draft: filled}} =
             edit(c, c.draft, %{type: "clock_delta", clock_id: c.source.id, delta: 2})

    assert {:ok, %{draft: reduced}} =
             edit(c, filled, %{type: "clock_delta", clock_id: c.source.id, delta: 0})

    assert reduced.payload["trigger_results"] == []
    assert reduced.payload["world_news"] == []
    assert Enum.find(reduced.payload["clocks"], &(&1["id"] == c.target.id))["paused"]

    assert {:ok, %{draft: restored}} =
             edit(c, reduced, %{type: "clock_delta", clock_id: c.source.id, delta: nil})

    assert restored.payload == c.draft.payload
    assert {:ok, _} = Ticks.publish_tick(c.campaign.id, c.tick.id, restored.id)
    assert Repo.get!(Clock, c.source.id).filled == 3
    assert Repo.get!(Clock, c.target.id).paused
  end

  test "explicit paused-clock deltas clamp while completed inputs cannot be overridden", c do
    assert {:ok, %{draft: lowered}} =
             edit(c, c.draft, %{type: "clock_delta", clock_id: c.target.id, delta: -100})

    target = Enum.find(lowered.payload["clocks"], &(&1["id"] == c.target.id))
    assert target["filled"] == 0
    assert target["paused"]

    assert {:ok, %{draft: restored}} =
             edit(c, lowered, %{type: "clock_delta", clock_id: c.target.id, delta: nil})

    assert restored.payload == c.draft.payload

    clocks =
      Enum.map(c.snapshot.data["clocks"], fn clock ->
        if clock["id"] == c.source.id, do: Map.put(clock, "completed", true), else: clock
      end)

    snapshot = %{c.snapshot | data: Map.put(c.snapshot.data, "clocks", clocks)}

    assert {:error, :invalid_snapshot} =
             WorldResolver.resolve(snapshot, %{"clock_deltas" => %{to_string(c.source.id) => 2}})
  end

  test "narration survives recomputation, suppression and clear restore generated news", c do
    assert {:ok, %{draft: narrated}} = edit(c, c.draft, %{type: "world_news", text: ["Authored"]})

    assert {:ok, %{draft: filled}} =
             edit(c, narrated, %{type: "clock_delta", clock_id: c.source.id, delta: 2})

    assert filled.payload["world_news"] == ["Authored"]
    assert {:ok, %{draft: suppressed}} = edit(c, filled, %{type: "world_news", text: []})
    assert suppressed.payload["world_news"] == []
    assert {:ok, %{draft: restored}} = edit(c, suppressed, %{type: "world_news", text: nil})
    assert restored.payload["world_news"] == ["The gate opens"]
  end

  test "review recomputation selects a different racing winner without loser triggers", c do
    group = Ecto.UUID.generate()

    clocks =
      Enum.map(c.snapshot.data["clocks"], fn clock ->
        cond do
          clock["id"] == c.source.id ->
            Map.merge(clock, %{"racing_group" => group, "background_rate" => 2})

          clock["id"] == c.public.id ->
            Map.merge(clock, %{"racing_group" => group, "filled" => 3, "background_rate" => 1})

          true ->
            clock
        end
      end)

    snapshot = %{c.snapshot | data: Map.put(c.snapshot.data, "clocks", clocks)}
    assert {:ok, initial} = WorldResolver.resolve(snapshot)
    assert [%{"clock_id" => source_id}] = initial["race_winners"]
    assert source_id == c.source.id
    assert initial["world_news"] == ["The gate opens"]

    assert {:ok, revised} =
             WorldResolver.resolve(snapshot, %{"clock_deltas" => %{to_string(c.source.id) => 0}})

    assert [%{"clock_id" => winner_id}] = revised["race_winners"]
    assert winner_id == c.public.id
    assert revised["world_news"] == []
    assert Enum.find(revised["clocks"], &(&1["id"] == c.source.id))["completed"]
    assert Enum.find(revised["clocks"], &(&1["id"] == c.target.id))["paused"]
  end

  test "invalid, foreign, unauthorized and stale edits leave no new revisions", c do
    operations = [
      %{type: "clock_delta", clock_id: 999_999, delta: 1},
      %{type: "clock_delta", clock_id: 999_999, delta: nil},
      %{type: "clock_delta", clock_id: c.source.id, delta: "2"},
      %{type: "clock_delta", clock_id: c.source.id, delta: 2, completed: true},
      %{type: "world_news", text: [""]},
      %{type: "world_news", text: [String.duplicate("x", 2001)]},
      %{type: "world_news", text: "not a list"}
    ]

    for operation <- operations, do: assert({:error, :invalid_edit} = edit(c, c.draft, operation))

    assert {:error, :unauthorized} =
             Ticks.edit_draft(
               c.campaign.id,
               c.tick.id,
               c.draft.id,
               %{type: "world_news", text: []},
               "999",
               "reason"
             )

    assert {:error, :invalid_reason} =
             Ticks.edit_draft(
               c.campaign.id,
               c.tick.id,
               c.draft.id,
               %{type: "world_news", text: []},
               "456",
               " "
             )

    assert {:error, :stale_draft} =
             edit(c, %{c.draft | id: Ecto.UUID.generate()}, %{type: "world_news", text: []})

    assert {:error, :not_found} =
             Ticks.edit_draft(
               999_999,
               c.tick.id,
               c.draft.id,
               %{type: "world_news", text: []},
               "456",
               "reason"
             )

    assert Repo.aggregate(Draft, :count) == 1
    assert Repo.aggregate(ReviewEdit, :count) == 0
  end

  test "publication fails closed on incompatible live clock or routing state", c do
    Repo.update!(change(c.source, filled: 1))
    assert {:error, :stale_live_state} = Ticks.publish_tick(c.campaign.id, c.tick.id, c.draft.id)
    Repo.update!(change(Repo.get!(Clock, c.source.id), filled: 2))
    Repo.update!(change(c.campaign, public_channel_id: "888"))
    assert {:error, :stale_live_state} = Ticks.publish_tick(c.campaign.id, c.tick.id, c.draft.id)
    assert Repo.aggregate(Publication, :count) == 0
    assert Deliveries.list_deliveries(c.campaign.id) == []
    assert Repo.get!(Tick, c.tick.id).status == :in_review
  end

  test "unvalidated low-level draft payloads cannot reach public preview or publication", c do
    assert {:ok, %{draft: tampered}} =
             Ticks.put_draft(
               c.campaign.id,
               c.tick.id,
               c.snapshot.revision,
               Map.put(c.draft.payload, "world_news", ["Unaudited"]),
               c.draft.id
             )

    assert {:error, :invalid_draft} = Ticks.publish_tick(c.campaign.id, c.tick.id, tampered.id)
    assert {:error, :invalid_draft} = Ticks.preview_draft(c.campaign.id, c.tick.id, tampered.id)
    assert {:error, :invalid_draft} = edit(c, tampered, %{type: "world_news", text: []})
    assert Deliveries.list_deliveries(c.campaign.id) == []
  end

  test "outbox failure after state/history writes rolls everything back", c do
    assert {:ok, %{draft: draft}} =
             edit(c, c.draft, %{type: "clock_delta", clock_id: c.source.id, delta: 2})

    key = "tick:#{c.tick.id}:public:789:0"

    {:ok, _} =
      Deliveries.enqueue(c.campaign.id, c.tick.id, %{
        key: key,
        kind: :public,
        recipient_id: "789",
        content: "Conflicting intent"
      })

    audit_count = length(Clocks.list_audits(c.campaign.id))
    jobs = Repo.aggregate(Oban.Job, :count)
    assert {:error, :delivery_conflict} = Ticks.publish_tick(c.campaign.id, c.tick.id, draft.id)
    assert Repo.get!(Clock, c.source.id).filled == 2
    refute Repo.get!(Clock, c.source.id).completed
    assert Repo.get!(Clock, c.target.id).paused
    assert length(Clocks.list_audits(c.campaign.id)) == audit_count
    assert Repo.aggregate(Publication, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert length(Deliveries.list_deliveries(c.campaign.id)) == 1
    assert Repo.get!(Tick, c.tick.id).status == :in_review
    assert Repo.get!(Campaign, c.campaign.id).current_tick_number == 0
    assert Repo.get!(Campaign, c.campaign.id).clock_mutations_locked
  end

  test "review audit and publication history reject updates in the database", c do
    {:ok, %{draft: draft, edit: audit}} =
      edit(c, c.draft, %{type: "world_news", text: ["Approved"]})

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(change(audit, reason: "Rewrite"), mode: :savepoint)
    end

    assert_raise Postgrex.Error, ~r/immutable/, fn -> Repo.delete!(audit, mode: :savepoint) end
    {:ok, _} = Ticks.publish_tick(c.campaign.id, c.tick.id, draft.id)
    {:ok, publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(change(publication, payload: %{}), mode: :savepoint)
    end

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.delete!(publication, mode: :savepoint)
    end

    assert {:ok, ^publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)
  end
end
