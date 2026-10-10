defmodule AsyncWorlds.DeliveriesTest do
  use AsyncWorlds.DataCase, async: false
  use Oban.Testing, repo: AsyncWorlds.Repo
  import ExUnit.CaptureLog
  alias AsyncWorlds.{Campaigns, Clocks, Deliveries, Ticks}
  alias AsyncWorlds.Discord.FakeAdapter
  alias AsyncWorlds.Workers.DeliverDiscord

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

    # Isolate delivery mechanics from the open-tick announcement tested by commands.
    tick =
      Repo.insert!(%AsyncWorlds.Ticks.Tick{
        campaign_id: campaign.id,
        number: 1,
        opened_at: DateTime.utc_now()
      })

    %{campaign: campaign.id, tick: tick}
  end

  defp attrs(kind \\ :public),
    do: %{key: "tick:1:news", kind: kind, recipient_id: "789", content: "Approved news"}

  defp run(delivery),
    do: perform_job(DeliverDiscord, %{delivery_id: delivery.id, generation: delivery.generation})

  defp fetch(delivery) do
    {:ok, delivery} = Deliveries.fetch_delivery(delivery.campaign_id, delivery.id)
    delivery
  end

  test "enqueue is scoped, validates payloads, and deduplicates identical intents", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, Map.put(attrs(), :status, :sent))
    assert delivery.status == :pending
    assert {:ok, ^delivery} = Deliveries.enqueue(id, tick.id, attrs())
    assert length(all_enqueued(worker: DeliverDiscord, args: %{delivery_id: delivery.id})) == 1

    assert {:error, :delivery_conflict} =
             Deliveries.enqueue(id, tick.id, Map.put(attrs(), :content, "Different"))

    assert {:error, _} = Deliveries.enqueue(id, tick.id, Map.put(attrs(), :recipient_id, "01"))

    assert {:error, _} =
             Deliveries.enqueue(
               id,
               tick.id,
               Map.put(attrs(), :content, String.duplicate("x", 2001))
             )

    assert {:error, _} = Deliveries.enqueue(id, tick.id, Map.put(attrs(), :content, " "))
    assert {:error, :not_found} = Deliveries.enqueue(id, -1, attrs())
    assert Deliveries.list_deliveries(id) == [delivery]
    assert Deliveries.list_deliveries(-1) == []
    assert {:error, :not_found} = Deliveries.fetch_delivery(-1, delivery.id)
    assert {:error, :not_found} = Deliveries.retry_delivery(-1, delivery.id, 0)
  end

  test "foreign ticks cannot create a cross-campaign delivery", %{tick: tick} do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    assert {:error, :not_found} = Deliveries.enqueue(other.id, tick.id, attrs())
  end

  test "publication transaction rolls back outbox and jobs together on failure", %{
    campaign: id,
    tick: tick
  } do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
    {:ok, %{draft: draft}} = Ticks.put_draft(id, tick.id, snapshot.revision, %{})

    assert {:error, :abort} =
             Ticks.publish_tick(id, tick.id, draft.id, fn _ ->
               assert {:ok, _} = Deliveries.enqueue(id, tick.id, attrs())
               {:error, :abort}
             end)

    assert Deliveries.list_deliveries(id) == []
    refute_enqueued(worker: DeliverDiscord)
    assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(id, tick.id)
    refute_receive {:discord, :send_public, _}
  end

  test "known public sends record IDs and duplicate jobs never resend", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    assert :ok = run(delivery)
    assert_receive {:discord, :send_public, {"789", payload}}
    assert payload.content == "Approved news"
    assert payload.allowed_mentions == %{parse: []}
    assert payload.enforce_nonce
    assert byte_size(payload.nonce) <= 25
    assert payload == DeliverDiscord.payload(delivery)

    assert %{status: :sent, message_id: "1001", channel_id: "789", attempts: 1, sent_at: sent_at} =
             fetch(delivery)

    assert sent_at
    assert :ok = run(delivery)
    refute_receive {:discord, :send_public, _}
    assert {:error, :not_retryable} = Deliveries.retry_delivery(id, delivery.id, 0)
  end

  test "blocked private DMs do not change game state or repeat publication; targeted retry is possible",
       %{campaign: id, tick: tick} do
    {:ok, clock} = Clocks.create_clock(id, %{name: "World", segments: 4}, "dm")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(id, tick.id)
    {:ok, %{draft: draft}} = Ticks.put_draft(id, tick.id, snapshot.revision, %{})

    {:ok, _} =
      Ticks.publish_tick(id, tick.id, draft.id, fn _ ->
        Deliveries.enqueue(id, tick.id, attrs(:private))
      end)

    [delivery] = Deliveries.list_deliveries(id)
    FakeAdapter.fail(:send_private, {:error, {:permanent, :forbidden}})
    assert {:cancel, :forbidden} = run(delivery)
    assert_receive {:discord, :send_private, {"789", _}}
    assert %{status: :failed, error_class: :permanent, last_error: "forbidden"} = fetch(delivery)
    assert :ok = run(delivery)
    refute_receive {:discord, :send_private, _}
    assert {:ok, %{status: :published}} = Ticks.fetch_tick(id, tick.id)
    assert Repo.get!(AsyncWorlds.Clocks.Clock, clock.id).filled == 0

    assert {:error, :already_published} =
             Ticks.publish_tick(id, tick.id, draft.id, fn _ -> flunk("must not publish again") end)

    FakeAdapter.fail(:send_private, nil)
    assert {:ok, retry} = Deliveries.retry_delivery(id, delivery.id, 0)
    assert retry.generation == 1
    assert {:error, :stale_delivery} = Deliveries.retry_delivery(id, delivery.id, 0)
    assert :ok = run(retry)
    assert_receive {:discord, :send_private, _}
    assert fetch(delivery).status == :sent
  end

  test "explicit rate-limit rejection retries safely and records a stable nonce", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    FakeAdapter.fail(:send_public, {:error, {:retryable, :rate_limited}})
    assert %{failure: 1} = Oban.drain_queue(queue: :discord_delivery)
    assert_receive {:discord, :send_public, {_, first}}
    assert %{status: :failed, error_class: :retryable, attempts: 1} = fetch(delivery)
    FakeAdapter.fail(:send_public, nil)

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :discord_delivery, with_scheduled: true)

    assert_receive {:discord, :send_public, {_, second}}
    assert first.nonce == second.nonce
    assert %{status: :sent, attempts: 2} = fetch(delivery)
  end

  test "ambiguous timeout requires confirmation, while old generations cannot send or settle", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    assert {:ok, claim} = Deliveries.claim(delivery.id, 0)
    assert {:ok, _} = Deliveries.settle(claim, {:error, {:ambiguous, :unknown_result}})
    assert :ok = run(delivery)
    refute_receive {:discord, :send_public, _}
    assert {:error, :confirmation_required} = Deliveries.retry_delivery(id, delivery.id, 0)

    assert {:error, :confirmation_required} =
             Deliveries.retry_delivery(id, delivery.id, 0, confirm_ambiguous: "true")

    assert {:ok, retry} = Deliveries.retry_delivery(id, delivery.id, 0, confirm_ambiguous: true)
    assert DeliverDiscord.payload(retry).nonce != DeliverDiscord.payload(delivery).nonce
    assert :ok = run(delivery)
    refute_receive {:discord, :send_public, _}

    assert {:error, :stale_attempt} =
             Deliveries.settle(claim, {:ok, %{message_id: "111", channel_id: "789"}})

    assert :ok = run(retry)
    assert_receive {:discord, :send_public, _}
  end

  test "unknown transport errors and exceptions are ambiguous and never expose error bodies", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    FakeAdapter.fail(:send_public, {:raise, "private-webhook-token-and-content"})

    log =
      capture_log(fn ->
        assert %{cancelled: 1} = Oban.drain_queue(queue: :discord_delivery)
      end)

    assert_receive {:discord, :send_public, _}
    assert %{status: :ambiguous, last_error: "unknown_result"} = fetch(delivery)
    refute log =~ "private-webhook-token-and-content"
    [job] = Repo.all(from j in Oban.Job, where: j.queue == "discord_delivery")
    refute inspect(job.errors) =~ "private-webhook-token-and-content"
    assert :ok = run(delivery)
    refute_receive {:discord, :send_public, _}
  end

  test "a timeout or malformed send receipt never triggers an automatic resend", %{
    campaign: id,
    tick: tick
  } do
    for {outcome, index} <-
          Enum.with_index([
            {:error, :timeout},
            {:error, {:retryable, :unknown_result}},
            {:ok, %{message_id: "bad", channel_id: "789"}}
          ]) do
      {:ok, delivery} =
        Deliveries.enqueue(id, tick.id, Map.put(attrs(), :key, "uncertain:#{index}"))

      FakeAdapter.fail(:send_public, outcome)
      assert {:cancel, :unknown_result} = run(delivery)
      assert_receive {:discord, :send_public, _}
      assert %{status: :ambiguous, attempts: 1} = fetch(delivery)
      assert :ok = run(delivery)
      refute_receive {:discord, :send_public, _}
    end
  end

  test "interrupted sending claims become ambiguous on recovery rather than being resent", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    assert {:ok, claim} = Deliveries.claim(delivery.id, 0)
    assert claim.status == :sending
    assert {:error, :not_retryable} = Deliveries.retry_delivery(id, delivery.id, 0)
    assert :ok = run(delivery)
    assert %{status: :ambiguous, last_error: "interrupted_send", attempts: 1} = fetch(delivery)
    refute_receive {:discord, :send_public, _}
    # A late definitive result can still settle the same attempt safely.
    assert {:ok, %{status: :sent}} =
             Deliveries.settle(claim, {:ok, %{message_id: "111", channel_id: "789"}})

    assert :ok = run(delivery)
    refute_receive {:discord, :send_public, _}
  end

  test "disabled bot leaves deliveries pending and snoozes without sending", %{
    campaign: id,
    tick: tick
  } do
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    Application.put_env(:async_worlds, :discord, enabled: false, adapter: FakeAdapter)
    assert {:snooze, 60} = run(delivery)
    assert %{status: :pending, attempts: 0} = fetch(delivery)
    refute_receive {:discord, :send_public, _}
  end

  test "pending deliveries survive a supervised Oban restart", %{campaign: id, tick: tick} do
    opts = [name: __MODULE__.Oban, repo: AsyncWorlds.Repo, testing: :manual]
    start_supervised!({Oban, opts})
    {:ok, delivery} = Deliveries.enqueue(id, tick.id, attrs())
    assert :ok = stop_supervised(__MODULE__.Oban)
    start_supervised!({Oban, opts})
    assert %{success: 1, failure: 0} = Oban.drain_queue(__MODULE__.Oban, queue: :discord_delivery)
    assert_receive {:discord, :send_public, _}
    assert fetch(delivery).status == :sent
  end
end
