defmodule AsyncWorldsWeb.TensionLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Clocks, Ticks}
  alias AsyncWorlds.DM.Tensions

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "91001",
        dm_user_id: "92002",
        public_channel_id: "93003"
      })

    %{
      conn: log_in_dm(conn, campaign),
      campaign: campaign,
      scope: %{campaign: campaign, discord_user_id: "92002"}
    }
  end

  test "Battle in the Reach can be created, reloaded and edited without the rule editor", c do
    {:ok, view, _} = live(c.conn, ~p"/tensions")
    assert has_element?(view, "#tensions-empty")

    view
    |> form("#tension-form",
      tension: %{name: "Battle in the Reach", description: "A contested crossing"}
    )
    |> render_submit()

    {:ok, [t]} = Tensions.list_tensions(c.scope)
    path = ~p"/tensions/#{t.id}"
    assert_redirect(view, path)
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#tension-status", "ongoing")
    assert has_element?(view, "#tension-circumstances", "contested crossing")
    refute has_element?(view, "input[name='tension[status]']")

    for {name, mode, empty, full, influences} <- [
          {"Battle balance", "tug_of_war", "Elven victory", "Goblin victory",
           "Ash Company holds the crossing"},
          {"Supply exhaustion", "countdown", "Stores intact", "Elves out of food",
           "Roads blocked"},
          {"Reinforcements", "countdown", "Distant army", "Goblins arrive", "Forced march"}
        ] do
      view
      |> form("#tension-clock-form",
        clock: %{
          name: name,
          mode: mode,
          segments: "8",
          filled: "4",
          empty_description: empty,
          full_description: full,
          influences: influences
        }
      )
      |> render_submit()
    end

    {:ok, [balance, _, _]} = Tensions.list_clocks(c.scope, t.id)
    assert balance.visibility == :hidden
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#clock-empty-#{balance.id}", "Elven victory")
    assert has_element?(view, "#clock-full-#{balance.id}", "Goblin victory")
    assert has_element?(view, "#clock-influences-#{balance.id}", "Ash Company")
    view |> element("#edit-tension-clock-#{balance.id}") |> render_click()

    view
    |> form("#tension-clock-form", clock: %{influences: "Neighbouring lords mobilise"})
    |> render_submit()

    assert has_element?(view, "#clock-influences-#{balance.id}", "Neighbouring lords")

    view
    |> form("#tension-form", tension: %{description: "The elves hold the crossing"})
    |> render_submit()

    assert_redirect(view, path)
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#tension-circumstances", "elves hold")
    assert has_element?(view, "#clock-empty-#{balance.id}", "Elven victory")
    assert has_element?(view, "#clock-full-#{balance.id}", "Goblin victory")
  end

  test "explicit public policy survives reload and discussion state/history link are visible to DM",
       c do
    {:ok, t} = Tensions.create_tension(c.scope, %{name: "Battle"})
    assert t.audience == :dm
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")
    assert has_element?(view, "#tension-audience option[value='dm'][selected]")
    refute has_element?(view, "#tension-discussion")
    view |> form("#tension-form", tension: %{audience: "public"}) |> render_submit()
    assert_redirect(view, ~p"/tensions/#{t.id}")
    {:ok, public} = Tensions.get_tension(c.scope, t.id)
    assert public.audience == :public
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")
    assert has_element?(view, "#tension-audience option[value='public'][selected]")
    assert has_element?(view, "#tension-discussion", "pending")
    {:ok, d} = AsyncWorlds.TensionDiscussions.get(c.scope, t.id)
    {:ok, {:create, claim}} = AsyncWorlds.TensionDiscussions.claim(d.id)
    {:ok, _} = AsyncWorlds.TensionDiscussions.settle(claim, {:ok, "9001"})
    view |> element("#refresh-tensions") |> render_click()

    assert has_element?(
             view,
             "#tension-discussion-link[href='https://discord.com/channels/91001/9001']"
           )
  end

  test "standalone association and detachment remain explicit and stale clock edits fail", c do
    {:ok, t} = Tensions.create_tension(c.scope, %{name: "Battle"})
    {:ok, clock} = Clocks.create_clock(c.campaign.id, %{name: "Existing", segments: 4}, "dm")
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")

    view
    |> form("#associate-clock-form", association: %{clock_id: to_string(clock.id)})
    |> render_submit()

    assert has_element?(view, "#edit-tension-clock-#{clock.id}")
    view |> element("#edit-tension-clock-#{clock.id}") |> render_click()
    {:ok, _} = Clocks.edit_clock(c.campaign.id, clock.id, %{name: "Changed elsewhere"}, "dm")
    view |> form("#tension-clock-form", clock: %{name: "Stale"}) |> render_submit()
    assert has_element?(view, "#flash-error", "changed")
    view |> element("#refresh-tensions") |> render_click()
    view |> element("#detach-clock-#{clock.id}") |> render_click()
    refute has_element?(view, "#edit-tension-clock-#{clock.id}")

    assert {:ok, %{tension_id: nil, visibility: :public}} =
             Clocks.get_clock(c.campaign.id, clock.id)
  end

  test "stale situation edits and closed-tick forged submits are rejected", c do
    {:ok, t} = Tensions.create_tension(c.scope, %{name: "Battle"})
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")
    {:ok, _} = Tensions.edit_tension(c.scope, t.id, %{description: "Fresh"}, t)
    view |> form("#tension-form", tension: %{description: "Stale"}) |> render_submit()
    assert has_element?(view, "#flash-error", "Tension changed")
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
    render_submit(view, "save", %{"tension" => %{"name" => "Locked"}})
    assert {:ok, %{name: "Battle", description: "Fresh"}} = Tensions.get_tension(c.scope, t.id)
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")
    assert has_element?(view, "#tension-lock-notice")
    assert has_element?(view, "#tension-form fieldset[disabled]")
    assert has_element?(view, "#tension-clock-form fieldset[disabled]")
  end

  test "malformed/missing IDs and foreign situations are not loaded", c do
    assert {:error, {:live_redirect, %{to: "/tensions"}}} = live(c.conn, ~p"/tensions/99999999")
    assert {:error, {:live_redirect, %{to: "/tensions"}}} = live(c.conn, "/tensions/not-an-id")

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "91002",
        dm_user_id: "92002",
        public_channel_id: "93003"
      })

    {:ok, t} = Tensions.create_tension(%{c.scope | campaign: other}, %{name: "Other"})
    assert {:error, {:live_redirect, %{to: "/tensions"}}} = live(c.conn, ~p"/tensions/#{t.id}")
  end

  test "detail-only events on the index fail safely without mutating clocks", c do
    {:ok, clock} = Clocks.create_clock(c.campaign.id, %{name: "Standalone", segments: 4}, "dm")
    {:ok, view, _} = live(c.conn, ~p"/tensions")

    for {event, params} <- [
          {"save-clock", %{"clock" => %{"name" => "Forged", "segments" => "4"}}},
          {"associate", %{"association" => %{"clock_id" => "bad"}}},
          {"edit-clock", %{"id" => to_string(clock.id)}},
          {"detach", %{"id" => to_string(clock.id)}},
          {"new-clock", %{}}
        ] do
      render_submit(view, event, params)
      assert has_element?(view, "#flash-error", "Invalid action")
      assert has_element?(view, "#tension-form")
    end

    assert Clocks.list_clocks(c.campaign.id) == [clock]
    assert {:ok, []} = Tensions.list_tensions(c.scope)
  end

  test "invalid and foreign clock events on a detail page fail safely", c do
    {:ok, t} = Tensions.create_tension(c.scope, %{name: "Battle"})

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "91003",
        dm_user_id: "92002",
        public_channel_id: "93003"
      })

    {:ok, foreign} = Clocks.create_clock(other.id, %{name: "Foreign", segments: 4}, "dm")
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")

    for id <- ["bad", "99999999", to_string(foreign.id)],
        {event, params} <- [
          {"edit-clock", %{"id" => id}},
          {"detach", %{"id" => id}},
          {"associate", %{"association" => %{"clock_id" => id}}}
        ] do
      render_submit(view, event, params)
      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#tension-detail")
    end

    assert {:ok, []} = Tensions.list_clocks(c.scope, t.id)
    assert {:ok, ^foreign} = Clocks.get_clock(other.id, foreign.id)
  end

  test "resolved situations retain read-only status presentation", c do
    {:ok, t} = Tensions.create_tension(c.scope, %{name: "Settled battle"})
    t |> Ecto.Changeset.change(status: :resolved) |> AsyncWorlds.Repo.update!()
    {:ok, view, _} = live(c.conn, ~p"/tensions/#{t.id}")
    assert has_element?(view, "#tension-status", "resolved")
    assert has_element?(view, "#tensions", "resolved")
    refute has_element?(view, "[name='tension[status]']")
  end

  test "anonymous and non-DM browser access denied", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/tensions")
    conn = log_in_dm(build_conn(), %{c.campaign | dm_user_id: "94004"})
    assert {:error, {:redirect, _}} = live(conn, ~p"/tensions")
  end
end
