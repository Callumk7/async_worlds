defmodule AsyncWorlds.DM.OperationsTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, DMAccess, Repo}
  alias AsyncWorlds.DM.{Clocks, Deliveries, Ticks}
  alias AsyncWorlds.Clocks.Audit
  alias AsyncWorlds.Ticks.WorldResolver

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
        public_channel_id: "790"
      })

    %{
      scope: %{campaign: campaign, discord_user_id: "456"},
      other: %{campaign: other, discord_user_id: "456"}
    }
  end

  defp operations(clock, tick, delivery) do
    [
      &Ticks.active_tick/1,
      &Ticks.latest_published_tick/1,
      &Ticks.status/1,
      &Ticks.fetch_tick(&1, tick.id),
      &Ticks.fetch_tick_by_number(&1, tick.number),
      &Ticks.fetch_ticks(&1, [tick.id]),
      &Ticks.fetch_snapshot(&1, tick.id),
      &Ticks.fetch_draft(&1, tick.id),
      &Ticks.resolution_jobs(&1, tick.id),
      &Ticks.list_review_edits(&1, tick.id),
      &Ticks.fetch_publication(&1, tick.id),
      &Ticks.open_tick/1,
      &Ticks.close_tick(&1, tick.id),
      &Ticks.close_active_tick/1,
      &Ticks.preview_draft(&1, tick.id, Ecto.UUID.generate()),
      &Ticks.edit_draft(
        &1,
        tick.id,
        Ecto.UUID.generate(),
        %{type: "world_news", text: []},
        "reason"
      ),
      &Ticks.publish_tick(&1, tick.id, Ecto.UUID.generate()),
      &Ticks.remind(&1, "999"),
      &Clocks.list_clocks/1,
      &Clocks.list_audits/1,
      &Clocks.recent_audits/1,
      &Clocks.create_clock(&1, %{name: "No", segments: 4}),
      &Clocks.edit_clock(&1, clock.id, %{name: "No"}),
      &Clocks.adjust_clock(&1, clock.id, 1),
      &Clocks.reset_clock(&1, clock.id),
      &Clocks.pair_clocks(&1, clock.id, clock.id),
      &Clocks.unpair_clock(&1, clock.id),
      &Deliveries.list_deliveries/1,
      &Deliveries.recent_deliveries/1,
      &Deliveries.search_deliveries/1,
      &Deliveries.fetch_delivery(&1, delivery.id),
      &Deliveries.retry_delivery(&1, delivery.id, delivery.generation)
    ]
  end

  test "every DM entry point rejects an unauthorized or revoked actor without side effects", %{
    scope: scope
  } do
    {:ok, clock} = Clocks.create_clock(scope, %{name: "Clock", segments: 4})
    {:ok, tick} = Ticks.open_tick(scope)
    {:ok, [delivery]} = Deliveries.list_deliveries(scope)
    calls = operations(clock, tick, delivery)
    before_jobs = Repo.aggregate(Oban.Job, :count)
    before_audits = Repo.aggregate(Audit, :count)

    for call <- calls do
      assert {:error, :unauthorized} = call.(%{scope | discord_user_id: "457"})
    end

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    for call <- calls, do: assert({:error, :unauthorized} = call.(scope))
    assert Repo.get!(AsyncWorlds.Ticks.Tick, tick.id).status == :open
    assert Repo.get!(AsyncWorlds.Clocks.Clock, clock.id) == clock
    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, delivery.id) == delivery
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
    assert Repo.aggregate(Audit, :count) == before_audits
  end

  test "invalid identities/scopes and stale configuration fail closed", %{scope: scope} do
    assert {:error, :invalid_scope} = Ticks.open_tick(scope.campaign.id)
    assert {:error, :invalid_scope} = Ticks.open_tick(%{scope | campaign: nil})
    assert {:error, :invalid_id} = Ticks.open_tick(%{scope | discord_user_id: "invalid"})
    assert {:ok, nil} = Ticks.active_tick(%{scope | discord_user_id: 456})

    {:ok, updated} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "790"
      })

    assert {:error, :stale_campaign} = Ticks.open_tick(scope)
    assert {:ok, _} = Ticks.open_tick(%{scope | campaign: updated})
  end

  test "foreign resources remain inaccessible even when the actor owns both campaigns", %{
    scope: scope,
    other: other
  } do
    {:ok, clock} = Clocks.create_clock(other, %{name: "Foreign", segments: 4})
    {:ok, tick} = Ticks.open_tick(other)
    {:ok, [delivery]} = Deliveries.list_deliveries(other)
    assert {:error, :not_found} = Clocks.adjust_clock(scope, clock.id, 1)
    assert {:error, :not_found} = Ticks.fetch_tick(scope, tick.id)
    assert {:error, :not_found} = Ticks.close_tick(scope, tick.id)
    assert {:error, :not_found} = Deliveries.fetch_delivery(scope, delivery.id)
    assert {:error, :not_found} = Deliveries.retry_delivery(scope, delivery.id, 0)
    assert {:ok, []} = Clocks.list_clocks(scope)
    assert {:ok, []} = Ticks.fetch_ticks(scope, [tick.id])
    assert {:ok, []} = Deliveries.search_deliveries(scope)
  end

  test "clock operations preserve audit attribution, stale checks, racing and tick locks", %{
    scope: scope
  } do
    {:ok, clock} = Clocks.create_clock(scope, %{name: "Clock", segments: 4}, :web)
    {:ok, other} = Clocks.create_clock(scope, %{name: "Other", segments: 4}, :discord)
    assert {:error, :invalid_source} = Clocks.adjust_clock(scope, clock.id, 1, "dm:web:999")
    assert {:ok, updated} = Clocks.edit_clock(scope, clock.id, %{paused: true}, :web, clock)

    assert {:error, :stale_clock} =
             Clocks.edit_clock(scope, clock.id, %{name: "Stale"}, :web, clock)

    assert {:ok, _} = Clocks.pair_clocks(scope, clock.id, other.id)
    assert {:ok, _} = Clocks.adjust_clock(scope, clock.id, 1)
    assert {:ok, %{filled: 0}} = Clocks.reset_clock(scope, clock.id)
    assert {:ok, _} = Clocks.unpair_clock(scope, clock.id)
    assert {:ok, audits} = Clocks.list_audits(scope)
    assert hd(audits).source == "dm:web:456"
    assert Enum.at(audits, 1).source == "dm:discord:456"
    assert List.last(audits).source == "dm:http:456"
    assert updated.paused
    {:ok, tick} = Ticks.open_tick(scope)
    assert {:error, :active_tick} = Ticks.open_tick(scope)
    assert {:ok, _} = Ticks.close_tick(scope, tick.id)
    assert {:error, :tick_locked} = Clocks.adjust_clock(scope, clock.id, 1)
  end

  test "review and publication preserve actor attribution, draft concurrency and outbox behavior",
       %{scope: scope} do
    {:ok, tick} = Ticks.open_tick(scope)
    {:ok, %{snapshot: snapshot}} = Ticks.close_active_tick(scope)
    {:ok, payload} = WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      AsyncWorlds.Ticks.put_draft(scope.campaign.id, tick.id, snapshot.revision, payload)

    assert {:ok, ^draft} = Ticks.fetch_draft(scope, tick.id)
    assert {:ok, _} = Ticks.preview_draft(scope, tick.id, draft.id)

    assert {:error, :invalid_reason} =
             Ticks.edit_draft(scope, tick.id, draft.id, %{type: "world_news", text: ["News"]}, "")

    assert {:ok, %{draft: revised, edit: edit}} =
             Ticks.edit_draft(
               scope,
               tick.id,
               draft.id,
               %{type: "world_news", text: ["News"]},
               "Correction"
             )

    assert edit.actor_id == "456"
    assert {:error, :stale_draft} = Ticks.publish_tick(scope, tick.id, draft.id)
    assert {:ok, %{status: :published}} = Ticks.publish_tick(scope, tick.id, revised.id)
    assert {:error, :already_published} = Ticks.publish_tick(scope, tick.id, revised.id)
    assert {:ok, publication} = Ticks.fetch_publication(scope, tick.id)
    assert publication.payload["world_news"] == ["News"]
    assert {:ok, deliveries} = Deliveries.list_deliveries(scope)
    assert Enum.any?(deliveries, &String.contains?(&1.content, "News"))
  end

  test "targeted retries retain generation and explicit ambiguous confirmation", %{scope: scope} do
    {:ok, _} = Ticks.open_tick(scope)
    {:ok, [delivery]} = Deliveries.list_deliveries(scope)
    Repo.update!(Ecto.Changeset.change(delivery, status: :ambiguous))

    assert {:error, :confirmation_required} =
             Deliveries.retry_delivery(scope, delivery.id, delivery.generation)

    assert {:ok, retried} =
             Deliveries.retry_delivery(scope, delivery.id, delivery.generation,
               confirm_ambiguous: true
             )

    assert retried.generation == delivery.generation + 1

    assert {:error, :stale_delivery} =
             Deliveries.retry_delivery(scope, delivery.id, delivery.generation,
               confirm_ambiguous: true
             )

    assert {:error, :not_retryable} =
             Deliveries.retry_delivery(scope, delivery.id, retried.generation)

    assert {:ok, %{status: :open}} = Ticks.active_tick(scope)
  end

  test "Discord DM commands do not rely only on dispatcher authorization", %{scope: scope} do
    context = %{campaign: scope.campaign, user_id: "457", interaction_id: "999"}

    for command <- [:tick_open, :tick_close, :tick_status, :tick_remind] do
      assert {:error, :unauthorized} = AsyncWorlds.Discord.Commands.execute(command, context)
    end

    assert {:ok, nil} = Ticks.active_tick(scope)
    assert {:ok, []} = Deliveries.list_deliveries(scope)
  end

  test "boundary unwraps results and rolls back callback failures", %{scope: scope} do
    assert {:ok, :value} = DMAccess.run(scope, fn _, _ -> {:ok, :value} end)

    assert {:error, :abort} =
             DMAccess.run(scope, fn c, _ ->
               assert {:ok, _} =
                        AsyncWorlds.Clocks.create_clock(
                          c.id,
                          %{name: "Rollback", segments: 4},
                          "internal"
                        )

               {:error, :abort}
             end)

    assert {:ok, []} = Clocks.list_clocks(scope)
    assert {:ok, []} = Clocks.list_audits(scope)
  end
end
