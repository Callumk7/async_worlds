defmodule AsyncWorldsWeb.DashboardReadinessLiveTest do
  use AsyncWorldsWeb.ConnCase
  use Oban.Testing, repo: AsyncWorlds.Repo

  import Ecto.Changeset
  import Phoenix.LiveViewTest

  alias AsyncWorlds.{Campaigns, Characters, Clocks, Deliveries, Quests, Repo, Ticks}
  alias AsyncWorlds.Discord.FakeAdapter
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Workers.DeliverDiscord

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    %{conn: log_in_dm(conn, campaign), campaign: campaign}
  end

  defp with_quest(campaign) do
    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "22002",
        %{content_id: "quest", name: "Quest"},
        AsyncWorlds.QuestFixtures.definition()
      )

    revision
  end

  test "without an active tick the roster explains the empty operational state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#roster-no-tick")
    assert has_element?(view, "#dashboard-freshness")
    refute has_element?(view, "#quest-readiness")
  end

  test "roster tracks submissions, clears, interventions and unassigned characters", c do
    {:ok, a} =
      Characters.create_character(c.campaign, "22002", %{name: "A", discord_user_id: "991"})

    {:ok, puppet} =
      Characters.create_character(c.campaign, "22002", %{name: "Puppet", discord_user_id: nil})

    revision = with_quest(c.campaign)
    {:ok, _} = Quests.assign(c.campaign, "22002", a.id, revision.id)
    {:ok, _} = Quests.assign(c.campaign, "22002", puppet.id, revision.id)
    {:ok, _tick} = Ticks.open_tick(c.campaign.id)

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#roster-state-#{a.id}", "Missing choice")
    assert has_element?(view, "#roster-state-#{puppet.id}", "Missing choice")
    assert has_element?(view, "#roster-unassigned-#{puppet.id}", "Unassigned")
    refute has_element?(view, "#roster-unassigned-#{a.id}")
    assert has_element?(view, "#quest-readiness", "0/2 quest choices ready · 2 missing")

    {:ok, state} = Submissions.player_state("11001", "991")
    assert {:ok, _} = Submissions.submit("11001", "991", state.identity, "loop")
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#roster-state-#{a.id}", "Submitted")
    assert has_element?(view, "#quest-readiness", "1/2 quest choices ready · 1 missing")

    assert {:ok, _} = Submissions.clear("11001", "991", state.identity)
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#roster-state-#{a.id}", "Missing choice")

    # DM interventions and assignments move rows between states coherently.
    {:ok, b} =
      Characters.create_character(c.campaign, "22002", %{name: "B", discord_user_id: "992"})

    {:ok, _} = Quests.assign(c.campaign, "22002", b.id, revision.id)
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#roster-state-#{b.id}", "Missing choice")

    progression =
      Repo.get_by!(AsyncWorlds.Quests.Progression, character_id: b.id, status: :active)

    {:ok, _} = Quests.end_quest(c.campaign, "22002", progression.id)
    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#roster-state-#{b.id}", "No active quest")
    assert has_element?(view, "#quest-readiness", "0/2 quest choices ready · 2 missing")
  end

  test "closing freezes the roster view and publication returns to the empty state", c do
    {:ok, a} =
      Characters.create_character(c.campaign, "22002", %{name: "A", discord_user_id: "991"})

    revision = with_quest(c.campaign)
    {:ok, _} = Quests.assign(c.campaign, "22002", a.id, revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state("11001", "991")
    assert {:ok, _} = Submissions.submit("11001", "991", state.identity, "finish")

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    view |> element("#close-tick") |> render_click()
    assert has_element?(view, "#roster-frozen")
    assert has_element?(view, "#roster-state-#{a.id}", "Submitted")

    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)

    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#roster-no-tick")
    refute has_element?(view, "#roster-frozen")
  end

  test "recent clock changes show names, tick attribution and hidden badges to the DM", c do
    {:ok, _tick} = Ticks.open_tick(c.campaign.id)

    {:ok, hidden} =
      Clocks.create_clock(
        c.campaign.id,
        %{name: "Hidden world clock", segments: 4, visibility: :hidden},
        "dm:web:22002"
      )

    {:ok, _} = Clocks.adjust_clock(c.campaign.id, hidden.id, 2, "dm:web:22002")

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#dashboard-clocks", "Hidden world clock")
    assert has_element?(view, "#dashboard-clocks", "hidden")
    assert has_element?(view, "#recent-fills", "Hidden world clock")
    assert has_element?(view, "#recent-fills", "adjust")
    assert has_element?(view, "#recent-fills", "dm:web:22002")
    assert has_element?(view, "#recent-fills", "Tick 1")

    [audit | _] = Clocks.recent_audits(c.campaign.id)
    assert has_element?(view, "#audit-tick-#{audit.id}", "Tick 1")
  end

  test "delivery status filters narrow by status, kind, recipient and tick", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    {:ok, failed_public} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "failed-public",
        kind: :public,
        recipient_id: "33003",
        content: "News"
      })

    {:ok, failed_private} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "failed-private",
        kind: :private,
        recipient_id: "22002",
        content: "Private"
      })

    Repo.update!(change(failed_public, status: :failed, error_class: :permanent))
    Repo.update!(change(failed_private, status: :failed, error_class: :permanent))

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#delivery-status-#{failed_public.id}", "failed")
    assert has_element?(view, "#delivery-status-#{failed_private.id}", "failed")

    all = %{status: "", kind: "", tick: "", recipient: ""}

    view |> form("#delivery-filters", filter: %{all | kind: "private"}) |> render_change()
    refute has_element?(view, "#delivery-status-#{failed_public.id}")
    assert has_element?(view, "#delivery-status-#{failed_private.id}")

    view
    |> form("#delivery-filters", filter: %{all | kind: "private", status: "sent"})
    |> render_change()

    refute has_element?(view, "#delivery-status-#{failed_private.id}")

    view
    |> form("#delivery-filters", filter: %{all | status: "failed", recipient: "22002"})
    |> render_change()

    refute has_element?(view, "#delivery-status-#{failed_public.id}")
    assert has_element?(view, "#delivery-status-#{failed_private.id}")

    view |> form("#delivery-filters", filter: %{all | tick: "1"}) |> render_change()
    assert has_element?(view, "#delivery-status-#{failed_public.id}")

    # Unknown tick numbers narrow to nothing instead of widening the search.
    view |> form("#delivery-filters", filter: %{all | tick: "99"}) |> render_change()
    refute has_element?(view, "#delivery-status-#{failed_public.id}")
    refute has_element?(view, "#delivery-status-#{failed_private.id}")
  end

  test "a targeted retry resends only that record through the delivery adapter", c do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, enabled: true, adapter: FakeAdapter)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    {:ok, public} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "public",
        kind: :public,
        recipient_id: "33003",
        content: "News"
      })

    {:ok, private} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "private",
        kind: :private,
        recipient_id: "991",
        content: "Secret"
      })

    Repo.update!(
      change(public, status: :failed, error_class: :permanent, last_error: "forbidden")
    )

    Repo.update!(
      change(private, status: :failed, error_class: :permanent, last_error: "forbidden")
    )

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    view |> form("#retry-delivery-#{private.id}") |> render_submit()

    {:ok, retry} = Deliveries.fetch_delivery(c.campaign.id, private.id)
    assert retry.status == :pending
    assert retry.generation == 1

    assert :ok =
             perform_job(DeliverDiscord, %{delivery_id: retry.id, generation: retry.generation})

    assert_receive {:discord, :send_private, {"991", payload}}
    assert payload.content == "Secret"
    refute_receive {:discord, :send_public, _}

    # The unrelated record is untouched and the tick was never republished.
    {:ok, untouched} = Deliveries.fetch_delivery(c.campaign.id, public.id)
    assert untouched.status == :failed
    assert untouched.generation == 0
    assert {:ok, %{status: :open}} = Ticks.fetch_tick(c.campaign.id, tick.id)
  end

  test "ambiguous retries still require explicit confirmation from the dashboard", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    {:ok, ambiguous} =
      Deliveries.enqueue(c.campaign.id, tick.id, %{
        key: "ambiguous",
        kind: :private,
        recipient_id: "22002",
        content: "Private"
      })

    Repo.update!(
      change(ambiguous, status: :ambiguous, error_class: :ambiguous, last_error: "timeout")
    )

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#delivery-status-#{ambiguous.id}", "ambiguous")
    assert has_element?(view, "#delivery-list", "timeout")

    view |> form("#retry-delivery-#{ambiguous.id}") |> render_submit()
    assert has_element?(view, "#flash-error", "possible duplicate")
    {:ok, unchanged} = Deliveries.fetch_delivery(c.campaign.id, ambiguous.id)
    assert unchanged.generation == 0

    view |> form("#retry-delivery-#{ambiguous.id}", retry: %{confirm: "true"}) |> render_submit()
    {:ok, updated} = Deliveries.fetch_delivery(c.campaign.id, ambiguous.id)
    assert updated.status == :pending
    assert updated.generation == 1
  end
end
