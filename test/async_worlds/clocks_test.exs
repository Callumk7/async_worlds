defmodule AsyncWorlds.ClocksTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Clocks}
  alias AsyncWorlds.Clocks.Clock

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

  defp create(campaign, attrs \\ %{}) do
    {:ok, clock} =
      Clocks.create_clock(campaign, Map.merge(%{name: "Ritual", segments: 4}, attrs), "dm:456")

    clock
  end

  test "validates sizes, visibility, rates, names and typed trigger payloads", %{campaign: id} do
    for attrs <- [
          %{segments: 5},
          %{name: " "},
          %{visibility: "secret"},
          %{background_rate: 1.5},
          %{triggers: [%{type: "flag", text: "no"}]},
          %{triggers: [%{type: "world_news"}]},
          %{triggers: [%{type: "start_clock", clock_id: 0}]},
          %{triggers: [%{type: "notify_dm", text: "hello", clock_id: 1}]}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Clocks.create_clock(id, Map.merge(%{name: "Clock", segments: 4}, attrs), "dm")
    end

    for size <- [4, 6, 8], visibility <- [:public, :known, :hidden] do
      clock = create(id, %{segments: size, visibility: visibility, background_rate: -2})
      assert clock.segments == size
      assert clock.visibility == visibility
      assert clock.background_rate == -2
    end
  end

  test "clamps create/edit/adjust, audits snapshots and protects ownership", %{
    campaign: id,
    other: other
  } do
    clock = create(id, %{filled: 99, campaign_id: other, completed: true})
    assert clock.filled == 4
    assert clock.campaign_id == id
    refute clock.completed
    assert {:ok, adjusted} = Clocks.adjust_clock(id, clock.id, -99, "dm:adjust")
    assert adjusted.filled == 0
    assert {:ok, edited} = Clocks.edit_clock(id, clock.id, %{segments: 6, filled: 99}, "dm:edit")
    assert edited.filled == 6
    assert {:error, :not_found} = Clocks.adjust_clock(other, clock.id, 1, "dm")
    assert {:error, :invalid_delta} = Clocks.adjust_clock(id, clock.id, "1", "dm")
    assert {:error, :invalid_source} = Clocks.adjust_clock(id, clock.id, 1, " ")
    [created, adjusted_audit, edited_audit] = Clocks.list_audits(id)
    assert created.before == %{}
    assert adjusted_audit.source == "dm:adjust"
    assert adjusted_audit.before["filled"] == 4
    assert adjusted_audit.after["filled"] == 0
    assert edited_audit.operation == "edit"
    assert length(Clocks.list_clocks(id)) == 1
    assert Clocks.list_clocks(other) == []
  end

  test "completion fires once, freezes fill and reset permits another completion", %{campaign: id} do
    clock =
      create(id, %{filled: 4, paused: true, triggers: [%{type: "world_news", text: "Done"}]})

    assert {:ok, %{clock: completed, actions: [action]}} =
             Clocks.complete_clock(id, clock.id, "dm")

    assert completed.completed
    assert action.type == :world_news
    assert {:error, :completed} = Clocks.complete_clock(id, clock.id, "dm")
    assert {:error, :completed} = Clocks.adjust_clock(id, clock.id, -1, "dm")
    assert {:error, :completed} = Clocks.edit_clock(id, clock.id, %{filled: 0}, "dm")
    assert {:ok, reset} = Clocks.reset_clock(id, clock.id, "dm")
    assert reset.filled == 0
    refute reset.completed
    assert reset.paused
    assert {:error, :not_filled} = Clocks.complete_clock(id, clock.id, "dm")
    assert {:ok, _} = Clocks.adjust_clock(id, clock.id, 4, "dm")
    assert {:ok, _} = Clocks.complete_clock(id, clock.id, "dm")
  end

  test "races prohibit self/cross-campaign/multiple membership; loser never fires; pair reset", %{
    campaign: id,
    other: other
  } do
    a = create(id, %{filled: 4})
    b = create(id, %{filled: 4, triggers: [%{type: "notify_dm", text: "Lost"}]})
    c = create(id)
    foreign = create(other)
    assert {:error, :self_link} = Clocks.pair_clocks(id, a.id, a.id, "dm")
    assert {:error, :not_found} = Clocks.pair_clocks(id, a.id, foreign.id, "dm")
    assert {:ok, [first, second]} = Clocks.pair_clocks(id, a.id, b.id, "dm")
    assert first.racing_group == second.racing_group
    assert {:error, :already_paired} = Clocks.pair_clocks(id, c.id, b.id, "dm")
    assert {:ok, %{actions: []}} = Clocks.complete_clock(id, a.id, "dm")
    assert Repo.get!(Clock, b.id).completed
    assert {:error, :completed} = Clocks.complete_clock(id, b.id, "dm")
    assert {:ok, _} = Clocks.reset_clock(id, b.id, "dm")
    refute Repo.get!(Clock, a.id).completed
    assert Repo.get!(Clock, a.id).filled == 0
    assert {:ok, _} = Clocks.unpair_clock(id, a.id, "dm")
    assert is_nil(Repo.get!(Clock, b.id).racing_group)
    assert {:ok, _} = Clocks.pair_clocks(id, c.id, b.id, "dm")
  end

  test "start references must exist in same campaign and cannot reference self", %{
    campaign: id,
    other: other
  } do
    clock = create(id)
    foreign = create(other)

    for target <- [foreign.id, clock.id, 999_999] do
      assert {:error, %Ecto.Changeset{}} =
               Clocks.edit_clock(
                 id,
                 clock.id,
                 %{triggers: [%{type: "start_clock", clock_id: target}]},
                 "dm"
               )
    end

    target = create(id, %{paused: true})

    assert {:ok, updated} =
             Clocks.edit_clock(
               id,
               clock.id,
               %{triggers: [%{type: "start_clock", clock_id: target.id}]},
               "dm"
             )

    assert hd(Repo.get!(Clock, updated.id).triggers).clock_id == target.id
  end

  test "invalid edits roll back state and audit; failed close rolls back the guard", %{
    campaign: id
  } do
    clock = create(id)
    audits = Clocks.list_audits(id)

    assert {:error, %Ecto.Changeset{}} =
             Clocks.edit_clock(id, clock.id, %{filled: 4, segments: 3}, "dm")

    assert Repo.get!(Clock, clock.id).filled == 0
    assert Clocks.list_audits(id) == audits

    assert {:error, :failed_snapshot} =
             Repo.transaction(fn ->
               assert {:ok, _} = Clocks.lock_mutations(id)
               Repo.rollback(:failed_snapshot)
             end)

    assert {:ok, _} = Clocks.adjust_clock(id, clock.id, 1, "dm")
  end

  test "draft rules leave persisted clocks and audits untouched", %{campaign: id} do
    clock = create(id, %{background_rate: 2})
    audits = Clocks.list_audits(id)
    draft = AsyncWorlds.Clocks.Rules.background(clock)
    assert draft.filled == 2
    assert Repo.get!(Clock, clock.id).filled == 0
    assert Clocks.list_audits(id) == audits
  end

  test "durable tick lock rejects every direct management write without auditing", %{campaign: id} do
    a = create(id)
    b = create(id)
    assert {:ok, _} = Clocks.lock_mutations(id)
    # Campaign setup cannot clear the guard.
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "456",
      public_channel_id: "789"
    })

    before = Clocks.list_audits(id)
    assert {:error, :tick_locked} = Clocks.create_clock(id, %{name: "new", segments: 4}, "dm")
    assert {:error, :tick_locked} = Clocks.edit_clock(id, a.id, %{paused: true}, "dm")
    assert {:error, :tick_locked} = Clocks.adjust_clock(id, a.id, 1, "dm")
    assert {:error, :tick_locked} = Clocks.reset_clock(id, a.id, "dm")
    assert {:error, :tick_locked} = Clocks.complete_clock(id, a.id, "dm")
    assert {:error, :tick_locked} = Clocks.pair_clocks(id, a.id, b.id, "dm")
    assert {:error, :tick_locked} = Clocks.unpair_clock(id, a.id, "dm")
    assert Clocks.list_audits(id) == before
    assert {:ok, _} = Clocks.unlock_mutations(id)
    assert {:ok, _} = Clocks.adjust_clock(id, a.id, 1, "dm")
  end
end
