defmodule AsyncWorldsWeb.ClockLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Clocks, Repo, Ticks, WebAuth}
  alias AsyncWorlds.Clocks.Clock

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    {:ok, clock} =
      Clocks.create_clock(campaign.id, %{name: "Storm", segments: 4, filled: 1}, "dm:test")

    %{conn: log_in_dm(conn, campaign), campaign: campaign, clock: clock}
  end

  test "create/edit forms validate inputs and save configured world triggers", c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    assert has_element?(view, "#clock-management")
    view |> form("#clock-form", clock: %{name: "", segments: "4"}) |> render_submit()
    assert has_element?(view, "#clock-form .text-error")
    assert length(Clocks.list_clocks(c.campaign.id)) == 1

    view |> element("#add-trigger") |> render_click()
    assert has_element?(view, "#trigger-0")

    view
    |> form("#clock-form",
      clock: %{
        name: "Rumours",
        segments: "6",
        filled: "2",
        visibility: "hidden",
        background_rate: "-1",
        paused: "true",
        triggers: %{"0" => %{type: "world_news", text: "The city stirs", clock_id: ""}}
      }
    )
    |> render_submit()

    created = Enum.find(Clocks.list_clocks(c.campaign.id), &(&1.name == "Rumours"))
    assert created.visibility == :hidden
    assert created.paused
    assert created.background_rate == -1
    assert [%{type: :world_news, text: "The city stirs"}] = created.triggers
    assert has_element?(view, "#edit-clock-#{created.id}")

    view |> element("#edit-clock-#{created.id}") |> render_click()

    view
    |> form("#clock-form",
      clock: %{
        name: "Whispers",
        segments: "8",
        visibility: "known",
        triggers: %{"0" => %{type: "notify_dm", text: "Private notice", clock_id: ""}}
      }
    )
    |> render_submit()

    updated = Repo.get!(Clock, created.id)
    assert updated.name == "Whispers"
    assert updated.segments == 8
    assert updated.visibility == :known
    assert hd(updated.triggers).type == :notify_dm

    view |> element("#edit-clock-#{created.id}") |> render_click()
    view |> element("#remove-trigger-0") |> render_click()
    refute has_element?(view, "#trigger-0")
    view |> form("#clock-form") |> render_submit()
    assert Repo.get!(Clock, created.id).triggers == []
  end

  test "start-clock trigger editor and invalid foreign references", c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#add-trigger") |> render_click()

    view
    |> form("#clock-form",
      clock: %{
        name: "Starter",
        triggers: %{"0" => %{type: "start_clock", text: "", clock_id: ""}}
      }
    )
    |> render_change()

    assert has_element?(view, "#clock_triggers_0_clock_id")

    view
    |> form("#clock-form",
      clock: %{
        name: "Starter",
        segments: "4",
        triggers: %{"0" => %{type: "start_clock", text: "", clock_id: to_string(c.clock.id)}}
      }
    )
    |> render_submit()

    starter = Enum.find(Clocks.list_clocks(c.campaign.id), &(&1.name == "Starter"))
    assert hd(starter.triggers).clock_id == c.clock.id

    view |> element("#edit-clock-#{starter.id}") |> render_click()

    render_submit(view, "save", %{
      "clock" => %{
        "name" => "Starter",
        "segments" => "4",
        "triggers" => %{"0" => %{"type" => "start_clock", "clock_id" => "999999", "text" => ""}}
      }
    })

    assert has_element?(view, "#flash-error", "another clock in this campaign")
    assert hd(Repo.get!(Clock, starter.id).triggers).clock_id == c.clock.id
  end

  test "adjust pause reset and racing links use domain operations", c do
    {:ok, other} = Clocks.create_clock(c.campaign.id, %{name: "Rival", segments: 4}, "dm:test")
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> form("#adjust-clock-#{c.clock.id}", adjust: %{delta: "2"}) |> render_submit()
    assert Repo.get!(Clock, c.clock.id).filled == 3
    view |> element("#pause-clock-#{c.clock.id}") |> render_click()
    assert Repo.get!(Clock, c.clock.id).paused
    view |> element("#pause-clock-#{c.clock.id}") |> render_click()
    refute Repo.get!(Clock, c.clock.id).paused

    view
    |> form("#race-form",
      race: %{first_id: to_string(c.clock.id), second_id: to_string(other.id)}
    )
    |> render_submit()

    assert Repo.get!(Clock, c.clock.id).racing_group == Repo.get!(Clock, other.id).racing_group
    view |> element("#reset-clock-#{c.clock.id}") |> render_click()
    assert Repo.get!(Clock, c.clock.id).filled == 0
    assert Repo.get!(Clock, other.id).filled == 0
    view |> element("#unpair-clock-#{c.clock.id}") |> render_click()
    assert Repo.get!(Clock, c.clock.id).racing_group == nil
    assert Repo.get!(Clock, other.id).racing_group == nil
    assert Enum.any?(Clocks.list_audits(c.campaign.id), &(&1.source == "dm:web:22002"))
  end

  test "an old pause button is idempotent rather than toggling newer state", c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    {:ok, _} = Clocks.edit_clock(c.campaign.id, c.clock.id, %{paused: true}, "dm:other")
    view |> element("#pause-clock-#{c.clock.id}") |> render_click()
    assert Repo.get!(Clock, c.clock.id).paused
  end

  test "stale editor cannot overwrite changes from another window", c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()

    {:ok, _} =
      Clocks.edit_clock(c.campaign.id, c.clock.id, %{name: "Changed elsewhere"}, "dm:other")

    view |> form("#clock-form", clock: %{name: "Stale name"}) |> render_submit()
    assert has_element?(view, "#flash-error", "changed in another window")
    assert Repo.get!(Clock, c.clock.id).name == "Changed elsewhere"
  end

  test "closed tick disables management and forged writes still fail", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    assert has_element?(view, "#clock-lock-notice")
    assert has_element?(view, "#clock-form fieldset[disabled]")
    assert has_element?(view, "#pause-clock-#{c.clock.id}[disabled]")
    render_click(view, "pause", %{"id" => to_string(c.clock.id), "paused" => "true"})
    assert has_element?(view, "#flash-error", "locked")
    refute Repo.get!(Clock, c.clock.id).paused
    render_submit(view, "save", %{"clock" => %{"name" => "Forbidden", "segments" => "4"}})
    assert length(Clocks.list_clocks(c.campaign.id)) == 1
  end

  test "completed clocks require reset before editing and invalid racing pairs are rejected", c do
    {:ok, filled} = Clocks.adjust_clock(c.campaign.id, c.clock.id, 3, "dm")
    {:ok, _} = Clocks.complete_clock(c.campaign.id, filled.id, "dm")
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    assert has_element?(view, "#edit-clock-#{c.clock.id}[disabled]")
    assert has_element?(view, "#pause-clock-#{c.clock.id}[disabled]")
    refute has_element?(view, "#reset-clock-#{c.clock.id}[disabled]")
    assert has_element?(view, "#pair-clocks[disabled]")

    render_submit(view, "pair", %{
      "race" => %{"first_id" => to_string(c.clock.id), "second_id" => to_string(c.clock.id)}
    })

    assert has_element?(view, "#flash-error", "different clocks")
    view |> element("#reset-clock-#{c.clock.id}") |> render_click()
    refute has_element?(view, "#edit-clock-#{c.clock.id}[disabled]")
    refute Repo.get!(Clock, c.clock.id).completed
  end

  test "foreign clock IDs and unauthenticated access are rejected", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11002",
        dm_user_id: "999",
        public_channel_id: "33004"
      })

    {:ok, foreign} = Clocks.create_clock(other.id, %{name: "Foreign", segments: 4}, "dm")
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    render_click(view, "pause", %{"id" => to_string(foreign.id), "paused" => "true"})
    assert has_element?(view, "#flash-error", "not available")
    refute Repo.get!(Clock, foreign.id).paused
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/clocks")
    :ok = WebAuth.revoke_session(get_session(get(c.conn, ~p"/dashboard"), :web_session_token))
    assert_redirect(view, ~p"/login")
  end
end
