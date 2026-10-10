defmodule AsyncWorlds.Discord.CommandsTest do
  use AsyncWorlds.DataCase, async: false
  use Oban.Testing, repo: AsyncWorlds.Repo
  import ExUnit.CaptureLog

  alias AsyncWorlds.{Campaigns, Clocks, Deliveries, Ticks}
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter, NostrumAdapter}
  alias AsyncWorlds.Workers.{DeliverDiscord, ResolveTick}

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, enabled: true, adapter: FakeAdapter)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    %{campaign: campaign, opts: opts}
  end

  defp invoke(c, command, id, user \\ 456) do
    data =
      case command do
        name when name in [:clocks, :admin] -> %{name: Atom.to_string(name)}
        name -> %{name: "tick", options: [%{type: 1, name: Atom.to_string(name)}]}
      end

    Dispatcher.handle(
      %{
        type: 2,
        id: id,
        application_id: 111,
        guild_id: 123,
        member: %{user_id: user},
        token: "private-token",
        data: data
      },
      c.opts
    )
  end

  defp clock(c, attrs) do
    {:ok, clock} = Clocks.create_clock(c.campaign.id, attrs, "dm")
    clock
  end

  defp deliver(delivery) do
    perform_job(DeliverDiscord, %{delivery_id: delivery.id, generation: delivery.generation})
  end

  test "players get live public fills and known names, never hidden clocks or draft state", c do
    clock(c, %{name: "Public", segments: 4, filled: 1, background_rate: 1})
    clock(c, %{name: "Known", segments: 6, filled: 3, visibility: :known})
    clock(c, %{name: "Hidden", segments: 8, filled: 7, visibility: :hidden})

    assert {:ok, "Public: 1/4\nKnown"} = invoke(c, :clocks, 1, 999)
    assert {:ok, _} = invoke(c, :open, 2)
    tick = Ticks.active_tick(c.campaign.id)
    assert {:ok, _} = invoke(c, :close, 3)
    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)

    assert :ok =
             perform_job(ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    assert {:ok, "Public: 1/4\nKnown"} = invoke(c, :clocks, 4, 999)
    refute_receive {:discord, :send_public, _}
  end

  test "DM lifecycle is repeat-safe, closes privately, and reports world-only readiness", c do
    assert {:ok, initial} = invoke(c, :status, 1)
    assert initial =~ "Ready to open"
    assert {:ok, "No active tick to close."} = invoke(c, :close, 2)
    assert {:ok, opened} = invoke(c, :open, 3)
    assert opened =~ "Tick 1 is open"
    assert {:ok, repeated} = invoke(c, :open, 4)
    assert repeated =~ "already active"
    assert {:ok, status} = invoke(c, :status, 5)
    assert status =~ "ready to close"
    assert status =~ "World-only"
    refute status =~ "submission count"

    tick = Ticks.active_tick(c.campaign.id)
    [announcement] = Deliveries.list_deliveries(c.campaign.id)
    assert announcement.key == "tick:#{tick.id}:opened"
    assert announcement.content == "Tick 1 is now open."
    assert :ok = deliver(announcement)
    assert :ok = deliver(announcement)
    assert_receive {:discord, :send_public, {"789", %{content: "Tick 1 is now open."}}}
    refute_receive {:discord, :send_public, _}

    assert {:ok, closed} = invoke(c, :close, 6)
    assert closed =~ "nothing is published automatically"
    assert {:ok, _} = invoke(c, :close, 7)
    assert length(all_enqueued(worker: ResolveTick)) == 1
    assert {:ok, status} = invoke(c, :status, 8)
    assert status =~ "private draft pending"
    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)

    assert :ok =
             perform_job(ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    assert {:ok, status} = invoke(c, :status, 9)
    assert status =~ "private draft ready"
    assert {:ok, _} = invoke(c, :close, 10)
    assert length(Deliveries.list_deliveries(c.campaign.id)) == 1
    assert {:error, :not_published} = Ticks.fetch_publication(c.campaign.id, tick.id)
    refute_receive {:discord, :send_public, _}
  end

  test "admin link is private and unauthorized production commands have no side effects", c do
    for {command, id} <- Enum.with_index([:open, :close, :status, :admin], 1) do
      assert {:error, :unauthorized} = invoke(c, command, id, 999)
      assert_receive {:discord, :defer, _}

      assert_receive {:discord, :edit_response,
                      {_, "This command is not available to you in this server."}}
    end

    assert is_nil(Ticks.active_tick(c.campaign.id))
    assert Deliveries.list_deliveries(c.campaign.id) == []
    assert {:ok, content} = invoke(c, :admin, 5)
    assert content =~ AsyncWorldsWeb.Endpoint.url() <> "/dashboard"
    assert content =~ "Sign in"
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, ^content}}
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
  end

  test "only approved publication delivers world news and privacy-filtered clocks", c do
    clock(c, %{name: "Public", segments: 4, background_rate: 1})
    clock(c, %{name: "Known", segments: 6, filled: 3, visibility: :known})

    clock(c, %{
      name: "Secret",
      segments: 4,
      visibility: :hidden,
      triggers: [%{type: :notify_dm, text: "Secret notification"}]
    })

    assert {:ok, _} = invoke(c, :open, 1)
    tick = Ticks.active_tick(c.campaign.id)
    assert {:ok, _} = invoke(c, :close, 2)
    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)

    assert :ok =
             perform_job(ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, tick.id)

    {:ok, %{draft: approved}} =
      Ticks.edit_draft(
        c.campaign.id,
        tick.id,
        draft.id,
        %{type: "world_news", text: ["Approved news"]},
        "456",
        "Narration"
      )

    assert length(Deliveries.list_deliveries(c.campaign.id)) == 1
    assert {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, approved.id)
    assert {:error, :already_published} = Ticks.publish_tick(c.campaign.id, tick.id, approved.id)

    deliveries = Deliveries.list_deliveries(c.campaign.id)
    assert length(deliveries) == 3
    for delivery <- deliveries, do: assert(:ok == deliver(delivery))
    assert_receive {:discord, :send_public, {"789", %{content: "Tick 1 is now open."}}}
    assert_receive {:discord, :send_public, {"789", payload}}
    assert payload.content =~ "Approved news"
    assert payload.content =~ "Public: 1/4"
    assert payload.content =~ "Known"
    refute payload.content =~ "3/6"
    refute payload.content =~ "Secret"
    assert payload.allowed_mentions == %{parse: []}
    assert_receive {:discord, :send_private, {"456", _}}
    refute_receive {:discord, :send_public, _}
    assert {:ok, status} = invoke(c, :status, 3)
    assert status =~ "ready to open the next"
    assert {:ok, next} = invoke(c, :open, 4)
    assert next =~ "Tick 2 is open"
  end

  test "large Unicode clock lists use private followups without losing or leaking content", c do
    for i <- 1..30 do
      clock(c, %{name: "#{i}-" <> String.duplicate("🌍", 100), segments: 4})
    end

    clock(c, %{name: "Secret", segments: 4, visibility: :hidden})
    assert {:ok, content} = invoke(c, :clocks, 1, 999)
    assert_receive {:discord, :edit_response, {_, first}}
    assert_receive {:discord, :followup_response, {_, second}}
    assert first <> second == content

    for chunk <- [first, second] do
      assert length(String.codepoints(chunk)) <= 2000
      assert String.valid?(chunk)
      refute chunk =~ "Secret"
    end

    assert byte_size(first) > 2000

    assert NostrumAdapter.followup_data(second) == %{
             content: second,
             flags: 64,
             allowed_mentions: %{parse: []}
           }

    refute_receive {:discord, :send_public, _}
  end

  test "failed replies never repeat a mutation and failed followups stop sending", c do
    FakeAdapter.fail(:edit_response, {:error, :offline})
    capture_log(fn -> assert {:error, :response_failed} = invoke(c, :open, 1) end)
    assert Ticks.active_tick(c.campaign.id).number == 1
    assert length(Deliveries.list_deliveries(c.campaign.id)) == 1
    FakeAdapter.fail(:edit_response, nil)
    assert {:ok, _} = invoke(c, :open, 2)
    assert length(Deliveries.list_deliveries(c.campaign.id)) == 1

    for i <- 1..50, do: clock(c, %{name: "#{i}-" <> String.duplicate("x", 180), segments: 4})
    FakeAdapter.fail(:followup_response, {:error, :offline})
    capture_log(fn -> assert {:error, :response_failed} = invoke(c, :clocks, 3) end)
    assert_receive {:discord, :followup_response, _}
    refute_receive {:discord, :followup_response, _}
  end

  test "empty clock replies are private even when all clocks are hidden", c do
    assert {:ok, "No visible clocks yet."} = invoke(c, :clocks, 1, 999)
    clock(c, %{name: "Hidden", segments: 4, visibility: :hidden})
    assert {:ok, "No visible clocks yet."} = invoke(c, :clocks, 2, 999)
    assert_receive {:discord, :edit_response, {_, "No visible clocks yet."}}
    refute_receive {:discord, :send_public, _}
  end

  test "acknowledgment failure prevents opening and domain errors get safe private replies", c do
    FakeAdapter.fail(:defer, {:error, "private-token"})
    log = capture_log(fn -> assert {:error, :acknowledgment_failed} = invoke(c, :open, 1) end)
    refute log =~ "private-token"
    assert is_nil(Ticks.active_tick(c.campaign.id))
    assert Deliveries.list_deliveries(c.campaign.id) == []
    refute_receive {:discord, :edit_response, _}

    FakeAdapter.fail(:defer, nil)
    c.campaign |> Ecto.Changeset.change(clock_mutations_locked: true) |> Repo.update!()
    assert {:error, :tick_locked} = invoke(c, :open, 2)

    assert_receive {:discord, :edit_response,
                    {_,
                     "The command could not be completed. Please check its status before retrying."}}

    assert Deliveries.list_deliveries(c.campaign.id) == []
  end

  test "open and its outbox intent roll back together on an outbox failure", c do
    Repo.query!(
      "ALTER TABLE discord_deliveries ADD CONSTRAINT reject_test_announcement CHECK (content <> 'Tick 1 is now open.') NOT VALID"
    )

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn -> Ticks.open_tick(c.campaign.id) end, mode: :savepoint)
    end

    assert is_nil(Ticks.active_tick(c.campaign.id))
    assert Deliveries.list_deliveries(c.campaign.id) == []
    refute_enqueued(worker: DeliverDiscord)
  end
end
