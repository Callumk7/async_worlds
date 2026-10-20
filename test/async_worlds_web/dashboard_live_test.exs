defmodule AsyncWorldsWeb.DashboardLiveTest do
  use AsyncWorldsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AsyncWorlds.{Campaigns, WebAuth}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn conn ->
      case conn.request_path do
        "/oauth2/token" -> Req.Test.json(conn, %{"access_token" => "test-access-token"})
        "/users/@me" -> Req.Test.json(conn, %{"id" => "22002"})
      end
    end)

    conn = get(conn, ~p"/auth/discord")

    state =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    conn = get(recycle(conn), ~p"/auth/discord/callback?code=test-code&state=#{state}")
    %{conn: recycle(conn), campaign: campaign, token: get_session(conn, :web_session_token)}
  end

  test "disconnected and connected mounts render only for the current DM", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#dm-dashboard")
    assert has_element?(view, "#campaign-summary")
    assert has_element?(view, "#logout-link")
  end

  test "DM explicitly adopts Tension-led participation and the next opening preview uses it", %{
    conn: conn,
    campaign: campaign
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(view, "#participation-mode-label", "Quest-centred")
    view |> element("#toggle-tension-participation") |> render_click()
    assert has_element?(view, "#participation-mode-label", "Tension-led")
    assert AsyncWorlds.Repo.reload!(campaign).tension_participation
    view |> form("#opening-form", opening: %{narration: ""}) |> render_submit()
    assert has_element?(view, "#opening-chunks", "without a quest")
    view |> element("#toggle-tension-participation") |> render_click()
    refute AsyncWorlds.Repo.reload!(campaign).tension_participation
    assert has_element?(view, "#opening-stale")
  end

  test "readiness is informational and missing choices never disable close", %{
    conn: conn,
    campaign: campaign
  } do
    {:ok, character} =
      AsyncWorlds.Characters.create_character(campaign, "22002", %{
        name: "Player",
        discord_user_id: "991"
      })

    {:ok, revision} =
      AsyncWorlds.Quests.create_quest(
        campaign,
        "22002",
        %{content_id: "quest", name: "Quest"},
        AsyncWorlds.QuestFixtures.definition()
      )

    {:ok, _} = AsyncWorlds.Quests.assign(campaign, "22002", character.id, revision.id)
    {:ok, _} = AsyncWorlds.Ticks.open_tick(campaign.id)
    {:ok, view, _} = live(conn, ~p"/dashboard")
    assert has_element?(view, "#quest-readiness", "0/1 quest choices ready")
    assert has_element?(view, "#close-tick:not([disabled])")
    view |> element("#close-tick") |> render_click()

    assert has_element?(
             view,
             "#resolution-pending",
             "Frozen quest choices and world inputs are queued"
           )

    assert has_element?(view, "#quest-readiness", "1 missing")
  end

  test "logout-style revocation disconnects an already connected socket", %{
    conn: conn,
    token: token
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    :ok = WebAuth.revoke_session(token)

    assert_redirect(view, ~p"/login")
  end

  test "expired sessions cannot dispatch connected events", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    AsyncWorlds.Repo.update_all(AsyncWorlds.WebAuth.Session,
      set: [expires_at: ~U[2000-01-01 00:00:00Z]]
    )

    view |> element("#refresh-authorization") |> render_click()
    assert_redirect(view, ~p"/login")
  end

  test "connected mount refuses a session revoked after HTTP render", %{conn: conn, token: token} do
    conn = get(conn, ~p"/dashboard")
    assert html_response(conn, 200) =~ "dm-dashboard"
    :ok = WebAuth.revoke_session(token)
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn)
  end

  test "unauthenticated HTTP requests cannot access administration" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/dashboard")
  end

  test "every event rechecks current campaign authorization", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    {:ok, _updated} =
      Campaigns.setup_campaign(%{
        discord_guild_id: campaign.discord_guild_id,
        dm_user_id: "99999",
        public_channel_id: campaign.public_channel_id
      })

    view |> element("#refresh-authorization") |> render_click()

    assert_redirect(view, ~p"/login")
  end
end
