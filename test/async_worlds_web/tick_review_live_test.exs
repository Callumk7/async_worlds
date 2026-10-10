defmodule AsyncWorldsWeb.TickReviewLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Clocks, Deliveries, Repo, Ticks}
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Ticks.WorldResolver

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
        %{
          name: "Secret threat",
          segments: 4,
          filled: 2,
          background_rate: 1,
          visibility: :hidden,
          triggers: [
            %{type: :world_news, text: "The gates open"},
            %{type: :notify_dm, text: "Secret notice"}
          ]
        },
        "dm"
      )

    {:ok, known} =
      Clocks.create_clock(
        campaign.id,
        %{name: "Known clock", segments: 6, filled: 3, visibility: :known},
        "dm"
      )

    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    %{
      conn: log_in_dm(conn, campaign),
      campaign: campaign,
      tick: tick,
      draft: draft,
      clock: clock,
      known: known,
      opening_deliveries: Deliveries.list_deliveries(campaign.id)
    }
  end

  test "review edits recompute consequences and exact public preview then publish", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    assert has_element?(view, "#tick-review")
    assert has_element?(view, "#draft-revision", "Revision 1")
    assert has_element?(view, "#public-preview", "Known clock")
    refute has_element?(view, "#public-preview", "Secret")
    refute has_element?(view, "#public-preview", "3/6")

    view
    |> form("#draft-clock-#{c.clock.id}", delta: %{amount: "2", reason: "Advance the storm"})
    |> render_submit()

    assert has_element?(view, "#draft-revision", "Revision 2")
    assert has_element?(view, "#clock-result-#{c.clock.id}", "4/4")
    assert has_element?(view, "#resolution-log", "review:tick:1:clock:#{c.clock.id}")
    assert has_element?(view, "#resolution-log", "Secret notice")
    assert has_element?(view, "#public-preview", "The gates open")
    refute has_element?(view, "#public-preview", "Secret")
    assert Repo.get!(Clock, c.clock.id).filled == 2

    view
    |> form("#world-news-form",
      news: %{text: "Approved public narration", reason: "Narration polish"}
    )
    |> render_submit()

    assert has_element?(view, "#draft-revision", "Revision 3")
    assert has_element?(view, "#public-preview", "Approved public narration")
    refute has_element?(view, "#public-preview", "The gates open")
    assert has_element?(view, "#review-audit", "Narration polish")
    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
    {:ok, preview} = Ticks.preview_draft(c.campaign.id, c.tick.id, draft.id)
    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(view, ~p"/dashboard")
    assert Repo.get!(Clock, c.clock.id).completed
    {:ok, publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)
    assert publication.outputs == preview
    assert length(Deliveries.list_deliveries(c.campaign.id)) == 3
  end

  test "stale revision disables actions until explicit reload", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    {:ok, _} =
      Ticks.edit_draft(
        c.campaign.id,
        c.tick.id,
        c.draft.id,
        %{type: "world_news", text: ["Other window"]},
        "22002",
        "Elsewhere"
      )

    view |> form("#world-news-form", news: %{text: "Stale", reason: "Attempt"}) |> render_submit()
    assert has_element?(view, "#flash-error", "another window")
    assert has_element?(view, "#stale-review")
    assert has_element?(view, "#publish-tick[disabled]")
    assert has_element?(view, "#world-news-form fieldset[disabled]")
    assert has_element?(view, "#save-draft-clock-#{c.clock.id}[disabled]")
    assert Deliveries.list_deliveries(c.campaign.id) == c.opening_deliveries
    view |> element("#refresh-review") |> render_click()
    refute has_element?(view, "#stale-review")
    assert has_element?(view, "#public-preview", "Other window")
    refute has_element?(view, "#publish-tick[disabled]")
  end

  test "stale publish approvals and incompatible live state cannot publish", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    {:ok, _} =
      Ticks.edit_draft(
        c.campaign.id,
        c.tick.id,
        c.draft.id,
        %{type: "world_news", text: ["Elsewhere"]},
        "22002",
        "Correction"
      )

    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert has_element?(view, "#flash-error", "another window")
    assert Deliveries.list_deliveries(c.campaign.id) == c.opening_deliveries
    assert has_element?(view, "#public-preview", "Elsewhere")
    Repo.update!(Ecto.Changeset.change(c.clock, filled: 1))
    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert has_element?(view, "#flash-error", "no longer match")
    assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(c.campaign.id, c.tick.id)
    assert Deliveries.list_deliveries(c.campaign.id) == c.opening_deliveries
  end

  test "missing confirmation and invalid audit edits leave state unchanged", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    view |> form("#publish-form") |> render_submit()
    assert has_element?(view, "#flash-error", "Confirm")

    view
    |> form("#draft-clock-#{c.clock.id}", delta: %{amount: "2", reason: ""})
    |> render_submit()

    assert has_element?(view, "#flash-error", "reason")

    render_submit(view, "edit_delta", %{
      "id" => to_string(c.clock.id),
      "delta" => %{"amount" => "not integer", "reason" => "Invalid", "draft_id" => c.draft.id}
    })

    assert has_element?(view, "#flash-error", "whole-number")
    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
    assert draft.id == c.draft.id
    assert Repo.get!(Clock, c.clock.id).filled == 2
    assert Deliveries.list_deliveries(c.campaign.id) == c.opening_deliveries
  end

  test "generated narration can be restored and overridden deltas cleared", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    view
    |> form("#draft-clock-#{c.clock.id}", delta: %{amount: "2", reason: "Fill"})
    |> render_submit()

    view |> form("#world-news-form", news: %{text: "", reason: "Suppress"}) |> render_submit()
    refute has_element?(view, "#public-preview", "The gates open")

    view
    |> form("#world-news-form", news: %{mode: "generated", reason: "Restore"})
    |> render_submit()

    assert has_element?(view, "#public-preview", "The gates open")

    view
    |> form("#draft-clock-#{c.clock.id}", delta: %{amount: "", reason: "Frozen rate"})
    |> render_submit()

    refute has_element?(view, "#public-preview", "The gates open")
    assert has_element?(view, "#clock-result-#{c.clock.id}", "3/4")
  end

  test "invalid draft payloads render a blocked preview rather than crashing", c do
    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, c.tick.id)

    {:ok, _} =
      Ticks.put_draft(
        c.campaign.id,
        c.tick.id,
        snapshot.revision,
        %{"clocks" => %{}, "world_news" => "invalid"},
        c.draft.id
      )

    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    assert has_element?(view, "#preview-error")
    assert has_element?(view, "#publish-tick[disabled]")
    assert has_element?(view, "#world-news-form fieldset[disabled]")
    assert has_element?(view, "#review-clocks-empty")
  end

  test "another campaign's real review cannot be loaded and navigation rechecks the DM", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11002",
        dm_user_id: "99999",
        public_channel_id: "33004"
      })

    {:ok, tick} = Ticks.open_tick(other.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(other.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, _} = Ticks.put_draft(other.id, tick.id, snapshot.revision, payload)

    assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
             live(c.conn, ~p"/ticks/#{tick.id}/review")

    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "88888",
        public_channel_id: "33003"
      })

    render_patch(view, ~p"/ticks/#{c.tick.id}/review")
    assert_redirect(view, ~p"/login")
  end

  test "review routes are campaign-scoped and event authorization stays fresh", c do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(build_conn(), ~p"/ticks/#{c.tick.id}/review")

    assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
             live(c.conn, ~p"/ticks/999999/review")

    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "99999",
        public_channel_id: "33003"
      })

    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(view, ~p"/login")
    assert Deliveries.list_deliveries(c.campaign.id) == c.opening_deliveries
  end
end
