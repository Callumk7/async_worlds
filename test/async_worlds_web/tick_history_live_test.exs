defmodule AsyncWorldsWeb.TickHistoryLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Deliveries, Quests, Repo, Ticks}
  alias AsyncWorlds.Ticks.History
  alias AsyncWorlds.WebAuth.Session

  test "empty history and navigation from dashboard and review", %{conn: conn} do
    campaign = history_campaign()
    conn = log_in_dm(conn, campaign)
    {:ok, view, _} = live(conn, ~p"/ticks/history")
    assert has_element?(view, "#published-ticks-empty")
    {:ok, dashboard, _} = live(conn, ~p"/dashboard")
    assert has_element?(dashboard, "#nav-history[href='/ticks/history']")
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, _} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)
    {:ok, review, _} = live(conn, ~p"/ticks/#{tick.id}/review")
    assert has_element?(review, "#nav-history[href='/ticks/history']")
  end

  test "list paginates and legacy details retain saved output with honest missing records", %{
    conn: conn
  } do
    campaign = history_campaign()
    ticks = for number <- 1..21, do: legacy_publication(campaign, number)
    first = hd(ticks)
    {:ok, view, _} = live(log_in_dm(conn, campaign), ~p"/ticks/history")
    refute has_element?(view, "#open-history-#{first.id}")
    view |> element("#history-next") |> render_click()
    assert has_element?(view, "#open-history-#{first.id}")
    refute has_element?(view, "#history-next")
    view |> element("#history-previous") |> render_click()
    refute has_element?(view, "#open-history-#{first.id}")
    {:ok, detail, _} = live(log_in_dm(build_conn(), campaign), ~p"/ticks/#{first.id}/history")
    assert has_element?(detail, "#history-world-news", "Legacy approved news 1")
    assert has_element?(detail, "#history-messages", "Legacy stored message 1")
    assert has_element?(detail, "#history-message-status-0", "No associated delivery record")
    assert has_element?(detail, "#history-results-empty")
    assert has_element?(detail, "#history-rolls-empty")
    refute has_element?(detail, "#publish-form")
    refute has_element?(detail, "#tick-history form")
  end

  test "approved quest history traces audits and stays immutable after later edits", %{conn: conn} do
    c = publish_history_quest(history_campaign())
    conn = log_in_dm(conn, c.campaign)
    {:ok, view, _} = live(conn, ~p"/ticks/#{c.tick.id}/history")
    assert has_element?(view, "#history-results", "Saved private narration")
    assert has_element?(view, "#history-results", "Original hero")
    assert has_element?(view, "#history-results", to_string(c.revision.id))
    assert has_element?(view, "#history-rolls", "6")
    assert has_element?(view, "#history-clocks", "Frozen secret clock")
    assert has_element?(view, "#history-consequences", "private_fact")
    assert has_element?(view, "#history-reviews", "Preserve this correction")
    assert has_element?(view, "#history-reviews", c.initial.id)
    assert has_element?(view, "#history-reviews", c.draft.id)
    assert has_element?(view, "#history-interventions", "Assignment during tick")
    assert has_element?(view, "#history-audits", "publish")
    assert has_element?(view, "#history-delivery-controls[href='/dashboard']")
    refute has_element?(view, "#tick-history form")

    {:ok, before} = History.fetch("11001", "22002", c.tick.id)

    {:ok, _} =
      Characters.update_character(c.campaign, "22002", c.character.id, %{name: "New hero"})

    {:ok, _} = Characters.clear_flag(c.campaign, "22002", c.character.id, "private_fact")

    {:ok, _} =
      Clocks.edit_clock(c.campaign.id, c.clock.id, %{name: "Renamed current clock"}, "dm")

    {:ok, _} = Clocks.adjust_clock(c.campaign.id, c.clock.id, -1, "dm")

    {:ok, _} =
      Quests.append_revision(
        c.campaign,
        "22002",
        c.revision.quest_id,
        AsyncWorlds.QuestFixtures.definition()
      )

    render_patch(view, ~p"/ticks/#{c.tick.id}/history")
    assert has_element?(view, "#history-clocks", "Frozen secret clock")
    refute has_element?(view, "#tick-history", "Renamed current clock")
    refute has_element?(view, "#tick-history", "New hero")
    assert {:ok, after_history} = History.fetch("11001", "22002", c.tick.id)
    assert after_history == before

    message = Enum.find(before.sections["messages"].items, &(&1.audience == "players"))
    assert has_element?(view, "#history-messages span", "character #{c.character.id}")
    assert has_element?(view, "#history-messages", "delivery #{message.delivery.id}")
    refute has_element?(view, "#history-messages", ~S(#{item.data.character_id}))
    refute has_element?(view, "#history-messages", ~S(#{item.data.delivery.id}))

    Repo.update!(
      Ecto.Changeset.change(message.delivery, status: :failed, last_error: "RAW_SECRET_EXCEPTION")
    )

    render_patch(view, ~p"/ticks/#{c.tick.id}/history")
    assert has_element?(view, "#history-messages", "failed")
    refute has_element?(view, "#tick-history", "RAW_SECRET_EXCEPTION")
    assert has_element?(view, "#history-results", "Saved private narration")
    {:ok, _} = Deliveries.retry_delivery(c.campaign.id, message.delivery.id, 0)
    render_patch(view, ~p"/ticks/#{c.tick.id}/history")
    assert has_element?(view, "#history-messages", "pending")
    assert has_element?(view, "#history-results", "Saved private narration")
  end

  test "routes reject unauthenticated, foreign, nonpublished and malformed IDs", %{conn: conn} do
    campaign = history_campaign()
    tick = publish_world(campaign)
    foreign = publish_world(history_campaign("11002", "22003"))
    {:ok, open} = Ticks.open_tick(campaign.id)
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/ticks/history")
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/ticks/#{tick.id}/history")
    conn = log_in_dm(conn, campaign)

    for id <- [foreign.id, open.id, "not-an-id", 999_999] do
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/ticks/#{id}/history")
    end

    assert {:error, {:live_redirect, %{to: "/dashboard"}}} = live(conn, "/ticks/history?page=-1")
    assert {:error, {:live_redirect, %{to: "/dashboard"}}} = live(conn, "/ticks/history?page[]=1")
  end

  test "message pagination patches only the selected section and preserves chunk order", %{
    conn: conn
  } do
    campaign = history_campaign()
    messages = for id <- 1..21, do: %{"recipient_id" => "33003", "content" => "Chunk #{id}"}

    tick =
      legacy_publication(campaign, 1,
        outputs: %{"public" => messages},
        payload: %{"private_results" => [%{"character_id" => 1, "text" => "Stable saved result"}]}
      )

    {:ok, view, _} = live(log_in_dm(conn, campaign), ~p"/ticks/#{tick.id}/history")
    assert has_element?(view, "#history-results", "historical name not recorded")
    assert has_element?(view, "#history-results", "Stable saved result")
    assert has_element?(view, "#history-messages-next")
    refute has_element?(view, "#history-messages", "Chunk 21")
    view |> element("#history-messages-next") |> render_click()
    assert has_element?(view, "#history-messages", "chunk 21")
    assert has_element?(view, "#history-messages", "Chunk 21")
    assert has_element?(view, "#history-results", "Stable saved result")
    refute has_element?(view, "#history-messages-next")
    view |> element("#history-messages-previous") |> render_click()
    refute has_element?(view, "#history-messages", "Chunk 21")
    assert has_element?(view, "#history-messages-next")
  end

  test "revoked sessions cannot keep browsing saved private history", %{conn: conn} do
    campaign = history_campaign()
    tick = publish_world(campaign)
    conn = log_in_dm(conn, campaign)
    {:ok, view, _} = live(conn, ~p"/ticks/#{tick.id}/history")
    AsyncWorlds.WebAuth.revoke_session(get_session(get(conn, ~p"/dashboard"), :web_session_token))
    assert_redirect(view, ~p"/login")
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/ticks/#{tick.id}/history")
  end

  test "stale navigation and expired sessions recheck authorization", %{conn: conn} do
    campaign = history_campaign()
    tick = publish_world(campaign)
    conn = log_in_dm(conn, campaign)
    {:ok, view, _} = live(conn, ~p"/ticks/#{tick.id}/history")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "55555",
        public_channel_id: "33003"
      })

    render_patch(view, ~p"/ticks/#{tick.id}/history")
    assert_redirect(view, ~p"/login")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    {:ok, expired, _} = live(conn, ~p"/ticks/history")
    Repo.update_all(Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    render_patch(expired, ~p"/ticks/history?page=2")
    assert_redirect(expired, ~p"/login")
  end
end
