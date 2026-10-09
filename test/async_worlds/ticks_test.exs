defmodule AsyncWorlds.TicksTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Clocks, Ticks}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Ticks.{Draft, Snapshot, Tick}

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
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign.id, other: other.id}
  end

  defp open(campaign) do
    {:ok, tick} = Ticks.open_tick(campaign)
    tick
  end

  defp review(campaign, tick) do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign, tick.id)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(campaign, tick.id, snapshot.revision, %{"world_news" => "A new day"})

    {snapshot, draft}
  end

  test "manual lifecycle, campaign numbering, timestamps and no next turn before publication", %{
    campaign: id
  } do
    tick = open(id)
    assert tick.status == :open
    assert tick.number == 1
    assert tick.opened_at
    assert Ticks.active_tick(id).id == tick.id
    assert Ticks.latest_published_tick(id) == nil
    assert {:error, :active_tick} = Ticks.open_tick(id)
    {snapshot, draft} = review(id, tick)
    assert snapshot.schema_version == 1
    assert draft.revision == 1
    assert draft.input_revision == snapshot.revision
    assert {:ok, reviewed} = Ticks.fetch_tick(id, tick.id)
    assert reviewed.closed_at && reviewed.reviewed_at
    assert reviewed.status == :in_review
    assert {:error, :active_tick} = Ticks.open_tick(id)

    assert {:ok, published} =
             Ticks.publish_tick(id, tick.id, draft.id, fn approved ->
               assert approved.snapshot.id == snapshot.id
               assert approved.draft.id == draft.id
               {:ok, :no_effects}
             end)

    assert published.status == :published
    assert published.published_at
    assert Ticks.latest_published_tick(id).id == tick.id
    assert is_nil(Ticks.active_tick(id))
    assert Repo.get!(Campaign, id).current_tick_number == 1
    refute Repo.get!(Campaign, id).clock_mutations_locked
    assert open(id).number == 2
  end

  test "close freezes every relevant input and stable clock/trigger order once", %{campaign: id} do
    {:ok, first} =
      Clocks.create_clock(
        id,
        %{
          name: "First",
          segments: 6,
          filled: 2,
          background_rate: -1,
          paused: true,
          visibility: :known
        },
        "dm"
      )

    {:ok, second} =
      Clocks.create_clock(
        id,
        %{
          name: "Second",
          segments: 8,
          visibility: :hidden,
          triggers: [
            %{type: :start_clock, clock_id: first.id},
            %{type: :world_news, text: "News"}
          ]
        },
        "dm"
      )

    {:ok, [first, second]} = Clocks.pair_clocks(id, first.id, second.id, "dm")
    tick = open(id)
    assert {:ok, _} = Clocks.adjust_clock(id, first.id, 1, "dm")
    assert {:ok, %{tick: closed, snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
    assert closed.status == :resolving
    assert snapshot.data["ordering"]["clocks"] == [first.id, second.id]
    assert snapshot.data["ordering"]["race_tie_break"] == "ascending_clock_id"
    assert snapshot.data["campaign"]["public_channel_id"] == "789"
    [frozen_first, frozen_second] = snapshot.data["clocks"]
    assert frozen_first["filled"] == 3
    assert frozen_first["paused"]
    assert frozen_first["background_rate"] == -1
    assert frozen_first["visibility"] == "known"
    assert frozen_first["racing_group"] == first.racing_group
    assert frozen_second["visibility"] == "hidden"
    assert Enum.map(frozen_second["triggers"], & &1["type"]) == ["start_clock", "world_news"]
    assert {:ok, %{snapshot: repeated}} = Ticks.close_tick(id, tick.id)
    assert repeated == snapshot
    assert Repo.aggregate(Snapshot, :count) == 1
    assert {:error, :tick_locked} = Clocks.adjust_clock(id, first.id, 1, "dm")
    assert {:error, :active_tick} = Clocks.unlock_mutations(id)

    assert {:ok, _} =
             Campaigns.setup_campaign(%{
               discord_guild_id: "123",
               dm_user_id: "999",
               public_channel_id: "888"
             })

    assert {:ok, ^snapshot} = Ticks.fetch_snapshot(id, tick.id)
    assert {:ok, %{draft: draft}} = Ticks.put_draft(id, tick.id, snapshot.revision, %{})
    assert {:ok, %{snapshot: ^snapshot}} = Ticks.close_tick(id, tick.id)
    assert {:ok, _} = Ticks.publish_tick(id, tick.id, draft.id, fn _ -> {:ok, :no_effects} end)
    assert {:ok, _} = Clocks.edit_clock(id, first.id, %{name: "Changed", filled: 0}, "dm")
    assert {:ok, ^snapshot} = Ticks.fetch_snapshot(id, tick.id)
  end

  test "drafts are append-only, revision-checked and never mutate published state", %{
    campaign: id
  } do
    {:ok, clock} = Clocks.create_clock(id, %{name: "World", segments: 4}, "dm")
    tick = open(id)
    {snapshot, draft} = review(id, tick)

    assert {:error, :stale_input} =
             Ticks.put_draft(id, tick.id, Ecto.UUID.generate(), %{}, draft.id)

    assert {:error, :stale_draft} = Ticks.put_draft(id, tick.id, snapshot.revision, %{})

    assert {:ok, %{draft: revised}} =
             Ticks.put_draft(id, tick.id, snapshot.revision, %{clock_fill: 4}, draft.id)

    assert revised.revision == 2
    assert revised.id != draft.id
    assert revised.payload == %{"clock_fill" => 4}
    assert Repo.get!(Draft, draft.id).payload == draft.payload
    assert {:ok, ^revised} = Ticks.fetch_draft(id, tick.id)
    assert Clocks.list_clocks(id) |> hd() |> Map.get(:filled) == 0
    assert Ticks.latest_published_tick(id) == nil

    assert {:error, :stale_draft} =
             Ticks.publish_tick(id, tick.id, draft.id, fn _ -> flunk("stale callback") end)

    assert {:ok, _} =
             Ticks.publish_tick(id, tick.id, revised.id, fn _ ->
               Repo.update!(change(clock, filled: 4))
               {:ok, :applied}
             end)

    assert Repo.get!(Clock, clock.id).filled == 4

    assert {:error, :already_published} =
             Ticks.publish_tick(id, tick.id, revised.id, fn _ -> flunk("duplicate callback") end)

    assert Repo.aggregate(Draft, :count) == 2
  end

  test "failed publication rolls back effects, number, guard and transition", %{campaign: id} do
    {:ok, clock} = Clocks.create_clock(id, %{name: "World", segments: 4}, "dm")
    tick = open(id)
    {_snapshot, draft} = review(id, tick)

    assert {:error, :outbox_failed} =
             Ticks.publish_tick(id, tick.id, draft.id, fn _ ->
               Repo.update!(change(clock, filled: 4))
               {:error, :outbox_failed}
             end)

    assert Repo.get!(Clock, clock.id).filled == 0
    assert Repo.get!(Tick, tick.id).status == :in_review
    assert Repo.get!(Campaign, id).current_tick_number == 0
    assert Repo.get!(Campaign, id).clock_mutations_locked

    assert {:error, :invalid_publication_result} =
             Ticks.publish_tick(id, tick.id, draft.id, fn _ -> :ok end)

    assert {:ok, _} = Ticks.publish_tick(id, tick.id, draft.id, fn _ -> {:ok, :retry} end)
  end

  test "invalid lifecycle transitions return useful errors", %{campaign: id} do
    tick = open(id)
    assert {:error, :not_closed} = Ticks.fetch_snapshot(id, tick.id)
    assert {:error, :no_draft} = Ticks.fetch_draft(id, tick.id)

    assert {:error, {:invalid_transition, :open, :publish}} =
             Ticks.publish_tick(id, tick.id, nil, fn _ -> flunk("early callback") end)

    assert {:error, {:invalid_transition, :open, :put_draft}} =
             Ticks.put_draft(id, tick.id, nil, %{})

    assert {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)

    assert {:error, {:invalid_transition, :resolving, :publish}} =
             Ticks.publish_tick(id, tick.id, nil, fn _ -> flunk("early callback") end)

    assert {:error, :invalid_payload} = Ticks.put_draft(id, tick.id, snapshot.revision, [])
    assert {:ok, %{draft: draft}} = Ticks.put_draft(id, tick.id, snapshot.revision, %{})
    assert {:ok, _} = Ticks.publish_tick(id, tick.id, draft.id, fn _ -> {:ok, :no_effects} end)
    assert {:error, {:invalid_transition, :published, :close}} = Ticks.close_tick(id, tick.id)

    assert {:error, {:invalid_transition, :published, :put_draft}} =
             Ticks.put_draft(id, tick.id, snapshot.revision, %{}, draft.id)
  end

  test "all ID-based reads and mutations stay within the campaign", %{campaign: id, other: other} do
    tick = open(id)
    {snapshot, draft} = review(id, tick)
    assert {:error, :not_found} = Ticks.fetch_tick(other, tick.id)
    assert {:error, :not_found} = Ticks.fetch_snapshot(other, tick.id)
    assert {:error, :not_found} = Ticks.fetch_draft(other, tick.id)
    assert {:error, :not_found} = Ticks.close_tick(other, tick.id)

    assert {:error, :not_found} =
             Ticks.put_draft(other, tick.id, snapshot.revision, %{}, draft.id)

    assert {:error, :not_found} =
             Ticks.publish_tick(other, tick.id, draft.id, fn _ -> flunk("foreign callback") end)

    assert {:error, :not_found} = Ticks.open_tick(999_999)
    assert is_nil(Ticks.active_tick(other))
    assert open(other).number == 1
  end

  test "failed outer close transaction leaves no snapshot or partial guard", %{campaign: id} do
    tick = open(id)

    assert {:error, :failed_close} =
             Repo.transaction(fn ->
               assert {:ok, _} = Ticks.close_tick(id, tick.id)
               Repo.rollback(:failed_close)
             end)

    assert Repo.get!(Tick, tick.id).status == :open
    refute Repo.get!(Campaign, id).clock_mutations_locked
    assert {:error, :not_closed} = Ticks.fetch_snapshot(id, tick.id)
    assert {:ok, _} = Ticks.close_tick(id, tick.id)
  end

  test "frozen tick state protects management even if guard is accidentally cleared", %{
    campaign: id
  } do
    {:ok, clock} = Clocks.create_clock(id, %{name: "World", segments: 4}, "dm")
    tick = open(id)
    review(id, tick)
    Repo.update!(change(Repo.get!(Campaign, id), clock_mutations_locked: false))
    assert {:error, :tick_locked} = Clocks.adjust_clock(id, clock.id, 1, "dm")
    assert {:error, :active_tick} = Clocks.unlock_mutations(id)
  end

  test "database refuses updates to frozen input records", %{campaign: id} do
    tick = open(id)
    {snapshot, _draft} = review(id, tick)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(change(snapshot, data: %{}), mode: :savepoint)
    end

    assert {:ok, ^snapshot} = Ticks.fetch_snapshot(id, tick.id)
  end

  test "database refuses updates to historical draft revisions", %{campaign: id} do
    tick = open(id)
    {_snapshot, draft} = review(id, tick)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(change(draft, payload: %{}), mode: :savepoint)
    end

    assert {:ok, ^draft} = Ticks.fetch_draft(id, tick.id)
  end

  test "database enforces one active tick, even for writers bypassing the context", %{
    campaign: id
  } do
    open(id)

    assert {:error, changeset} =
             %Tick{campaign_id: id, number: 2, opened_at: DateTime.utc_now()}
             |> change()
             |> unique_constraint(:campaign_id, name: :one_active_tick_per_campaign)
             |> Repo.insert()

    assert %{campaign_id: [_]} = errors_on(changeset)
  end
end
