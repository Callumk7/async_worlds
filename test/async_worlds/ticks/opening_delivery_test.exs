defmodule AsyncWorlds.Ticks.OpeningDeliveryTest do
  use AsyncWorlds.DataCase, async: false
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Quests, Repo, Ticks}
  alias AsyncWorlds.DM
  alias AsyncWorlds.Discord.FakeAdapter
  alias AsyncWorlds.Workers.DeliverDiscord

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, char} =
      Characters.create_character(campaign, "456", %{name: "Scout", discord_user_id: "991"})

    definition =
      update_in(
        definition(),
        ["nodes", Access.at(0)],
        &Map.put(&1, "public_summary", "Public patrol")
      )

    {:ok, rev} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "SECRET quest", content_id: "quest"},
        definition
      )

    {:ok, _} = Quests.assign(campaign, "456", char.id, rev.id)
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, enabled: true, adapter: FakeAdapter)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)
    %{campaign: campaign, char: char, scope: %{campaign: campaign, discord_user_id: "456"}}
  end

  defp deliver(d),
    do:
      DeliverDiscord.perform(%Oban.Job{
        args: %{"delivery_id" => d.id, "generation" => d.generation}
      })

  test "reviewed chunks, narration and guarded prompts persist atomically and public output is safe",
       c do
    narration = String.duplicate("x", 1817) <> "\r\n🌍é\r" <> String.duplicate("🌍", 600)
    {:ok, prepared} = DM.Ticks.prepare_opening(c.scope, %{"narration" => narration})
    assert length(prepared.messages) > 1
    {:ok, tick} = DM.Ticks.open_prepared_tick(c.scope, prepared.token)
    {:ok, briefing} = DM.Ticks.fetch_briefing(c.scope, tick.id)
    assert briefing.narration == prepared.narration
    assert briefing.input_version == prepared.version
    assert briefing.renderer_version == AsyncWorlds.Ticks.OpeningOutput.version()
    assert briefing.public_channel_id == "789"

    assert briefing.outputs["messages"] ==
             Enum.map(prepared.messages, fn m ->
               %{
                 "chunk_index" => m.chunk_index,
                 "content" => m.content,
                 "recipient_id" => m.recipient_id,
                 "kind" => "public"
               }
             end)

    deliveries = Deliveries.list_deliveries(c.campaign.id)
    public = Enum.filter(deliveries, &(&1.kind == :public))
    assert Enum.map(public, & &1.content) == Enum.map(prepared.messages, & &1.content)

    assert Enum.map(public, & &1.key) ==
             for(m <- prepared.messages, do: "tick:#{tick.id}:opened:#{m.chunk_index}")

    assert Enum.all?(public, &(not String.contains?(&1.content, "SECRET")))
    assert Enum.any?(deliveries, &(&1.kind == :private and &1.guard != %{}))
    assert Repo.aggregate(Oban.Job, :count) == length(deliveries)
    assert {:error, :active_tick} = DM.Ticks.open_prepared_tick(c.scope, prepared.token)
    assert Deliveries.list_deliveries(c.campaign.id) == deliveries
  end

  test "stored briefings reject updates and deletes while permitting tick cascade", c do
    {:ok, tick} = DM.Ticks.open_tick(c.scope)
    {:ok, briefing} = DM.Ticks.fetch_briefing(c.scope, tick.id)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update!(Ecto.Changeset.change(briefing, narration: "rewritten"), mode: :savepoint)
    end

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.delete!(briefing, mode: :savepoint)
    end

    assert {:ok, ^briefing} = DM.Ticks.fetch_briefing(c.scope, tick.id)
    Repo.delete!(tick)
    assert Repo.get(AsyncWorlds.Ticks.Briefing, briefing.id) == nil
  end

  test "saved briefing reads remain campaign scoped and freshly authorized", c do
    {:ok, tick} = DM.Ticks.open_tick(c.scope)

    assert {:error, :unauthorized} =
             DM.Ticks.fetch_briefing(%{c.scope | discord_user_id: "999"}, tick.id)

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "456",
        public_channel_id: "790"
      })

    assert {:error, :not_found} = DM.Ticks.fetch_briefing(%{c.scope | campaign: other}, tick.id)
    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "999"))
    assert {:error, :unauthorized} = DM.Ticks.fetch_briefing(c.scope, tick.id)
  end

  test "whitespace-only chunks are omitted before review and every saved chunk is transport-valid",
       c do
    {:ok, prepared} =
      DM.Ticks.prepare_opening(c.scope, %{
        "narration" => "start" <> String.duplicate("\n", 4000) <> "end"
      })

    assert Enum.all?(prepared.messages, &(String.trim(&1.content) != ""))

    assert Enum.map(prepared.messages, & &1.chunk_index) ==
             Enum.to_list(1..length(prepared.messages))

    assert {:ok, _} = DM.Ticks.open_prepared_tick(c.scope, prepared.token)
    outgoing = Deliveries.list_deliveries(c.campaign.id) |> Enum.filter(&(&1.kind == :public))
    assert Enum.map(outgoing, & &1.content) == Enum.map(prepared.messages, & &1.content)

    for delivery <- outgoing do
      assert :ok = deliver(delivery)
      assert_receive {:discord, :send_public, {"789", payload}}
      assert payload.content == delivery.content
      assert String.trim(payload.content) != ""
    end
  end

  test "failure while enqueuing private prompts rolls back tick, saved briefing, public chunks and jobs",
       c do
    Repo.query!(
      "ALTER TABLE discord_deliveries ADD CONSTRAINT reject_opening_private CHECK (kind <> 'private') NOT VALID"
    )

    {:ok, prepared} = DM.Ticks.prepare_opening(c.scope)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn -> DM.Ticks.open_prepared_tick(c.scope, prepared.token) end,
        mode: :savepoint
      )
    end

    assert Ticks.active_tick(c.campaign.id) == nil
    assert Repo.aggregate(AsyncWorlds.Ticks.Briefing, :count) == 0
    assert Deliveries.list_deliveries(c.campaign.id) == []
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "failed delivery and worker restart use saved bytes; targeted retry does not reopen or resend prompts",
       c do
    {:ok, prepared} =
      DM.Ticks.prepare_opening(c.scope, %{"narration" => String.duplicate("🌍", 1000)})

    {:ok, tick} = DM.Ticks.open_prepared_tick(c.scope, prepared.token)
    [first, second | prompts] = Deliveries.list_deliveries(c.campaign.id)
    assert first.kind == :public and second.kind == :public
    FakeAdapter.fail(:send_public, {:error, {:permanent, :forbidden}})
    assert {:cancel, :forbidden} = deliver(second)
    assert_receive {:discord, :send_public, _}
    {:ok, failed} = Deliveries.fetch_delivery(c.campaign.id, second.id)
    assert failed.status == :failed

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.char.id, %{name: "Changed roster"})

    assert Ticks.active_tick(c.campaign.id).id == tick.id
    assert {:ok, retried} = DM.Deliveries.retry_delivery(c.scope, failed.id, failed.generation)
    stop_supervised!(FakeAdapter)
    start_supervised!({FakeAdapter, owner: self()})
    # A restarted transport and newly reconstructed job load the persisted delivery;
    # no preparation in memory is used.
    assert :ok = deliver(retried)
    assert_receive {:discord, :send_public, {"789", payload}}
    assert payload.content == second.content
    assert :ok = deliver(retried)
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
    assert {:ok, ^first} = Deliveries.fetch_delivery(c.campaign.id, first.id)

    for prompt <- prompts,
        do: assert({:ok, ^prompt} = Deliveries.fetch_delivery(c.campaign.id, prompt.id))

    assert Repo.aggregate(AsyncWorlds.Ticks.Tick, :count) == 1
    assert {:ok, stored} = DM.Ticks.fetch_briefing(c.scope, tick.id)

    assert Enum.map(stored.outputs["messages"], & &1["content"]) ==
             Enum.map(prepared.messages, & &1.content)
  end
end
