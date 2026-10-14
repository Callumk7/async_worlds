defmodule AsyncWorldsWeb.TickOpeningLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Characters, Repo, Ticks, WebAuth}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    conn = conn |> log_in_dm(campaign) |> get(~p"/dashboard")

    %{
      conn: recycle(conn),
      campaign: campaign,
      token: get_session(conn, :web_session_token),
      scope: %{campaign: campaign, discord_user_id: "22002"}
    }
  end

  defp prepare(view, text \\ "") do
    view |> form("#opening-form", opening: %{narration: text}) |> render_submit()
  end

  test "empty roster preparation shows destination and every exact chunk without writes", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    assert has_element?(view, "#opening-form")

    narration =
      "<script>not executed</script> {literal} @everyone\n" <> String.duplicate("🌍 opening ", 500)

    {:ok, expected} = AsyncWorlds.DM.Ticks.prepare_opening(c.scope, %{"narration" => narration})
    prepare(view, narration)
    assert has_element?(view, "#opening-channel", "33003")
    assert has_element?(view, "#opening-approval")
    assert length(expected.messages) > 1
    refute has_element?(view, "#opening-chunks script")

    for chunk <- expected.messages do
      selector = "#opening_chunks-#{chunk.id} .whitespace-pre-wrap"
      assert has_element?(view, selector)

      assert view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
               chunk.content
    end

    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Ticks.active_tick(c.campaign.id) == nil
  end

  test "a chunk-leading newline survives parsed preview text", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    narration = String.duplicate("x", 1817)
    {:ok, expected} = AsyncWorlds.DM.Ticks.prepare_opening(c.scope, %{"narration" => narration})
    assert String.starts_with?(Enum.at(expected.messages, 1).content, "\n")
    prepare(view, narration)

    for chunk <- expected.messages do
      assert view
             |> element("#opening_chunks-#{chunk.id} .whitespace-pre-wrap")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text() == chunk.content
    end
  end

  test "CRLF and CR narration has exact canonical context and parsed preview chunks", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    narration = "first\r\nsecond\rthird"
    {:ok, expected} = AsyncWorlds.DM.Ticks.prepare_opening(c.scope, %{"narration" => narration})
    {:ok, repeated} = AsyncWorlds.DM.Ticks.preview_opening(c.scope, expected.token)
    assert repeated.messages == expected.messages
    assert Enum.map_join(expected.messages, "", & &1.content) =~ "first\nsecond\nthird"
    prepare(view, narration)

    for chunk <- expected.messages do
      refute chunk.content =~ "\r"

      assert view
             |> element("#opening_chunks-#{chunk.id} .whitespace-pre-wrap")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text() == chunk.content
    end
  end

  test "mixed roster preview includes player, DM-controlled and no-decision states", c do
    {:ok, scout} =
      Characters.create_character(c.campaign, "22002", %{name: "Scout", discord_user_id: "991"})

    {:ok, dm} = Characters.create_character(c.campaign, "22002", %{name: "DM Scout"})

    {:ok, _} =
      Characters.create_character(c.campaign, "22002", %{name: "Idle", discord_user_id: "992"})

    definition =
      update_in(
        AsyncWorlds.QuestFixtures.definition(),
        ["nodes", Access.at(0)],
        &Map.put(&1, "public_summary", "Public patrol")
      )

    {:ok, revision} =
      AsyncWorlds.Quests.create_quest(
        c.campaign,
        "22002",
        %{name: "SECRET Quest", content_id: "patrol"},
        definition
      )

    for character <- [scout, dm],
        do:
          assert(
            {:ok, _} = AsyncWorlds.Quests.assign(c.campaign, "22002", character.id, revision.id)
          )

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view, "Independent welcome")
    assert has_element?(view, "#opening-chunks", "Scout: Public patrol")
    assert has_element?(view, "#opening-chunks", "DM handles this quest decision")
    assert has_element?(view, "#opening-chunks", "Idle: No quest decision required.")
    assert has_element?(view, "#opening-chunks", "Independent welcome")
    refute has_element?(view, "#opening-chunks", "SECRET Quest")
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == 0
    assert Ticks.active_tick(c.campaign.id) == nil
  end

  test "confirmation required; tampered browser token cannot replace server inspected content",
       c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view)
    view |> form("#opening-approval") |> render_submit()
    assert Ticks.active_tick(c.campaign.id) == nil

    render_submit(view, "open_prepared_tick", %{
      "approval" => %{"confirm" => "true"},
      "token" => "foreign",
      "campaign_id" => "999"
    })

    assert Ticks.active_tick(c.campaign.id) == nil
    view |> form("#opening-approval", approval: %{confirm: true}) |> render_submit()
    assert Ticks.active_tick(c.campaign.id).number == 1
    refute has_element?(view, "#opening-preview")
    assert has_element?(view, "#close-tick:not([disabled])")
  end

  test "changed roster rejects opening and retains old preview until deliberate inspection", c do
    {:ok, char} =
      Characters.create_character(c.campaign, "22002", %{
        name: "Old Scout",
        discord_user_id: "991"
      })

    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view)
    assert has_element?(view, "#opening-chunks", "Old Scout")
    {:ok, _} = Characters.update_character(c.campaign, "22002", char.id, %{name: "New Scout"})
    view |> form("#opening-approval", approval: %{confirm: true}) |> render_submit()
    assert has_element?(view, "#opening-stale")
    assert has_element?(view, "#open-prepared-tick[disabled]")
    assert has_element?(view, "#opening-chunks", "Old Scout")
    refute has_element?(view, "#opening-chunks", "New Scout")
    assert Ticks.active_tick(c.campaign.id) == nil
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == 0
    # A forged enabled click also cannot bypass inspection.
    render_submit(view, "open_prepared_tick", %{"approval" => %{"confirm" => "true"}})
    assert Ticks.active_tick(c.campaign.id) == nil
    prepare(view)
    refute has_element?(view, "#opening-stale")
    assert has_element?(view, "#opening-chunks", "New Scout")
    view |> form("#opening-approval", approval: %{confirm: true}) |> render_submit()
    assert Ticks.active_tick(c.campaign.id).number == 1
  end

  test "explicit refresh checks changed destination without silently replacing preview", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: c.campaign.discord_guild_id,
        dm_user_id: "22002",
        public_channel_id: "33004"
      })

    view |> element("#refresh-authorization") |> render_click()
    assert has_element?(view, "#opening-stale")
    assert has_element?(view, "#opening-channel", "33003")
    prepare(view)
    assert has_element?(view, "#opening-channel", "33004")
    refute has_element?(view, "#opening-stale")
    assert Ticks.active_tick(c.campaign.id) == nil
  end

  test "editing narration invalidates inspection and invalid input cannot open", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view, "Original narration")
    view |> form("#opening-form", opening: %{narration: "Changed narration"}) |> render_change()
    assert has_element?(view, "#opening-stale")
    assert has_element?(view, "#opening-chunks", "Original narration")

    render_submit(view, "prepare_opening", %{
      "opening" => %{"narration" => "Safe", "world_news" => "Not opening"}
    })

    assert has_element?(view, "#open-prepared-tick[disabled]")
    assert Ticks.active_tick(c.campaign.id) == nil
  end

  test "revoked DM cannot prepare or open", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: c.campaign.discord_guild_id,
        dm_user_id: "99999",
        public_channel_id: "33003"
      })

    render_submit(view, "open_prepared_tick", %{"approval" => %{"confirm" => "true"}})
    assert_redirect(view, ~p"/login")
    assert Ticks.active_tick(c.campaign.id) == nil
  end

  test "expired session cannot prepare or open", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view)
    Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    render_submit(view, "open_prepared_tick", %{"approval" => %{"confirm" => "true"}})
    assert_redirect(view, ~p"/login")
    assert Ticks.active_tick(c.campaign.id) == nil
  end

  test "revoked session cannot inspect a prepared opening", c do
    {:ok, view, _} = live(c.conn, ~p"/dashboard")
    prepare(view)
    :ok = WebAuth.revoke_session(c.token)
    assert_redirect(view, ~p"/login")
    assert Ticks.active_tick(c.campaign.id) == nil
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/dashboard")
  end
end
