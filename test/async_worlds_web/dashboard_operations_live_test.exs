defmodule AsyncWorldsWeb.DashboardOperationsLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  import Ecto.Changeset
  alias AsyncWorlds.{Campaigns, Clocks, Deliveries, Repo, Ticks}
  alias AsyncWorlds.Workers.ResolveTick

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    {:ok, clock} =
      Clocks.create_clock(
        campaign.id,
        %{name: "Hidden world clock", segments: 4, visibility: :hidden, background_rate: 1},
        "dm"
      )

    %{conn: log_in_dm(conn, campaign), campaign: campaign, clock: clock}
  end

  test "dashboard opens closes and surfaces durable processing before review", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#dashboard-clocks", "Hidden world clock")
    assert has_element?(view, "#recent-fills", "create")
    view |> element("#open-tick") |> render_click()
    assert has_element?(view, "#open-tick[disabled]")
    assert has_element?(view, "#tick-status", "open")
    tick = Ticks.active_tick(c.campaign.id)
    view |> element("#close-tick") |> render_click()
    assert has_element?(view, "#resolution-pending")
    assert has_element?(view, "#close-tick[disabled]")
    {:ok, [job]} = Ticks.resolution_jobs(c.campaign.id, tick.id)
    Repo.update!(change(job, state: "retryable", attempt: 1))
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#resolution-jobs", "retryable")
    assert :ok = ResolveTick.perform(job)
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#review-tick[href='/ticks/#{tick.id}/review']")
    assert has_element?(view, "#tick-status", "in review")
  end

  test "failed and ambiguous deliveries support only targeted confirmed retries", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    {:ok, failed} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "failed",
        kind: :public,
        recipient_id: "33003",
        content: "News"
      })

    {:ok, ambiguous} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "ambiguous",
        kind: :private,
        recipient_id: "22002",
        content: "Private"
      })

    Repo.update!(
      change(failed, status: :failed, error_class: :permanent, last_error: "forbidden")
    )

    Repo.update!(
      change(ambiguous, status: :ambiguous, error_class: :ambiguous, last_error: "timeout")
    )

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#delivery-list", "forbidden")
    view |> form("#retry-delivery-#{failed.id}") |> render_submit()
    {:ok, updated} = Deliveries.fetch_delivery(c.campaign.id, failed.id)
    assert updated.status == :pending
    assert updated.generation == 1
    refute has_element?(view, "#retry-delivery-#{failed.id}")
    view |> form("#retry-delivery-#{ambiguous.id}") |> render_submit()
    assert has_element?(view, "#flash-error", "possible duplicate")
    {:ok, unchanged} = Deliveries.fetch_delivery(c.campaign.id, ambiguous.id)
    assert unchanged.generation == 0
    view |> form("#retry-delivery-#{ambiguous.id}", retry: %{confirm: "true"}) |> render_submit()
    {:ok, updated} = Deliveries.fetch_delivery(c.campaign.id, ambiguous.id)
    assert updated.status == :pending
    assert updated.generation == 1
    assert {:ok, %{status: :open}} = Ticks.fetch_tick(c.campaign.id, tick.id)
    assert c.campaign.current_tick_number == 0
  end

  test "stale delivery generations and foreign delivery IDs cannot be retried", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    {:ok, delivery} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "retry",
        kind: :public,
        recipient_id: "33003",
        content: "News"
      })

    Repo.update!(change(delivery, status: :failed, error_class: :permanent))
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    {:ok, _} = Deliveries.retry_delivery(c.campaign.id, delivery.id, 0)
    view |> form("#retry-delivery-#{delivery.id}") |> render_submit()
    assert has_element?(view, "#flash-error", "changed")
    {:ok, current} = Deliveries.fetch_delivery(c.campaign.id, delivery.id)
    assert current.generation == 1

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11002",
        dm_user_id: "999",
        public_channel_id: "33004"
      })

    {:ok, foreign_tick} = Ticks.open_tick(other.id)

    {:ok, foreign} =
      Deliveries.enqueue(other.id, foreign_tick.id, %{
        key: "foreign",
        kind: :public,
        recipient_id: "33004",
        content: "Other world"
      })

    Repo.update!(change(foreign, status: :failed, error_class: :permanent))

    render_submit(view, "retry_delivery", %{
      "id" => to_string(foreign.id),
      "retry" => %{"generation" => "0"}
    })

    assert has_element?(view, "#flash-error", "not available")
    {:ok, unchanged} = Deliveries.fetch_delivery(other.id, foreign.id)
    assert unchanged.generation == 0
  end

  test "dashboard refresh sees publication without relying on its mount-time counter", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#current-tick-number", "1")
    assert has_element?(view, "#dashboard-clocks", "1/4")
    refute has_element?(view, "#open-tick[disabled]")
    assert has_element?(view, "#delivery-list", "pending")
  end
end
