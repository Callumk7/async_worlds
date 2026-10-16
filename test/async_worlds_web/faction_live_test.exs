defmodule AsyncWorldsWeb.FactionLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias AsyncWorlds.{Campaigns, Factions, Repo}
  alias AsyncWorlds.Factions.Faction

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{
      campaign: campaign,
      scope: %{campaign: campaign, discord_user_id: "456"},
      conn: log_in_dm(conn, campaign)
    }
  end

  test "deleting a faction with members fails without removing links", c do
    {:ok, faction} = Factions.create_faction(c.scope, %{name: "Guild"})
    {:ok, character} = AsyncWorlds.Characters.create_character(c.campaign, "456", %{name: "Mira"})
    {:ok, membership} = AsyncWorlds.Memberships.join(c.scope, character.id, faction.id)
    {:ok, view, _} = live(c.conn, ~p"/factions")
    view |> element("#edit-faction-#{faction.id}") |> render_click()
    view |> element("#delete-faction") |> render_click()
    assert has_element?(view, "#flash-error", "Remove this faction's current memberships")
    assert has_element?(view, "#edit-faction-#{faction.id}")
    assert Repo.get!(AsyncWorlds.Factions.Membership, membership.id)
  end

  test "dashboard navigation leads to faction CRUD with streamed list", c do
    {:ok, dashboard, _} = live(c.conn, ~p"/dashboard")
    result = dashboard |> element("#nav-factions") |> render_click()
    {:ok, view, _} = follow_redirect(result, c.conn)
    assert has_element?(view, "#nav-factions[aria-current=page]")
    assert has_element?(view, "#factions-empty")
    assert has_element?(view, "#managed-factions[phx-update=stream]")

    view
    |> form("#faction-form", faction: %{name: "Guild", description: "First\nSecond"})
    |> render_submit()

    {:ok, [faction]} = Factions.list_factions(c.scope)
    assert faction.description == "First\nSecond"
    assert has_element?(view, "#edit-faction-#{faction.id}")
    assert has_element?(view, "#delete-faction[data-confirm]")

    view |> element("#new-faction") |> render_click()
    refute has_element?(view, "#delete-faction")
    view |> element("#edit-faction-#{faction.id}") |> render_click()
    assert has_element?(view, "#faction_name[value=Guild]")
    view |> form("#faction-form", faction: %{name: "Renamed", description: ""}) |> render_submit()
    assert Repo.get!(Faction, faction.id).name == "Renamed"
    assert Repo.get!(Faction, faction.id).description == nil
    view |> element("#delete-faction") |> render_click()
    refute has_element?(view, "#edit-faction-#{faction.id}")
    refute has_element?(view, "#delete-faction")
    assert {:ok, []} = Factions.list_factions(c.scope)
  end

  test "invalid input renders field errors without persisting", c do
    {:ok, view, _} = live(c.conn, ~p"/factions")

    for name <- ["", String.duplicate("a", 201), "bad" <> <<0>>] do
      render_submit(view, "save", %{"faction" => %{"name" => name}})
      assert has_element?(view, "#faction-form .text-error")
      assert {:ok, []} = Factions.list_factions(c.scope)
    end

    view |> form("#faction-form", faction: %{name: "Valid"}) |> render_submit()
    {:ok, [faction]} = Factions.list_factions(c.scope)
    render_submit(view, "save", %{"faction" => %{"name" => ""}})
    assert has_element?(view, "#faction-form .text-error")
    assert Repo.get!(Faction, faction.id).name == "Valid"
  end

  test "foreign IDs and supplied ownership cannot grant access; deletion is server-pinned", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Factions.create_faction(%{campaign: other, discord_user_id: "457"}, %{name: "Foreign"})

    {:ok, view, _} = live(c.conn, ~p"/factions")
    refute has_element?(view, "#edit-faction-#{foreign.id}")
    render_click(view, "edit", %{"id" => foreign.id})
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#delete-faction")

    render_submit(view, "save", %{
      "faction" => %{
        "name" => "Own",
        "campaign_id" => other.id,
        "id" => foreign.id,
        "discord_user_id" => "457"
      }
    })

    {:ok, [own]} = Factions.list_factions(c.scope)
    assert own.campaign_id == c.campaign.id
    render_click(view, "delete", %{"id" => foreign.id})
    refute Repo.get(Faction, own.id)
    assert Repo.get!(Faction, foreign.id) == foreign
  end

  test "missing selected targets fail safely rather than creating a replacement", c do
    {:ok, faction} = Factions.create_faction(c.scope, %{name: "Guild"})
    {:ok, view, _} = live(c.conn, ~p"/factions")
    view |> element("#edit-faction-#{faction.id}") |> render_click()
    {:ok, _} = Factions.delete_faction(c.scope, faction.id)
    view |> form("#faction-form", faction: %{name: "No"}) |> render_submit()
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#delete-faction")
    assert {:ok, []} = Factions.list_factions(c.scope)
  end

  test "unauthenticated sessions are redirected and expired sessions cannot write", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/factions")
    {:ok, view, _} = live(c.conn, ~p"/factions")
    Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    render_submit(view, "save", %{"faction" => %{"name" => "No"}})
    assert_redirect(view, ~p"/login")
    assert {:ok, []} = Factions.list_factions(c.scope)
  end

  test "DM configuration changes revoke an open editor", c do
    {:ok, faction} = Factions.create_faction(c.scope, %{name: "Guild"})
    {:ok, view, _} = live(c.conn, ~p"/factions")
    view |> element("#edit-faction-#{faction.id}") |> render_click()
    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "555"))
    view |> element("#delete-faction") |> render_click()
    assert_redirect(view, ~p"/login")
    assert Repo.get!(Faction, faction.id) == faction
  end

  test "authorization lost after the event hook clears private editor state", c do
    {:ok, faction} = Factions.create_faction(c.scope, %{name: "Private"})

    socket =
      %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
        assigns: %{__changed__: %{}, flash: %{}}
      }
      |> Phoenix.Component.assign(:current_scope, c.scope)

    {:ok, socket} = AsyncWorldsWeb.FactionLive.mount(%{}, %{}, socket)

    {:noreply, socket} =
      AsyncWorldsWeb.FactionLive.handle_event("edit", %{"id" => faction.id}, socket)

    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "555"))

    for {event, params} <- [
          {"new", %{}},
          {"delete", %{}},
          {"save", %{"faction" => %{"name" => "No"}}}
        ] do
      {:noreply, rejected} = AsyncWorldsWeb.FactionLive.handle_event(event, params, socket)
      assert {:redirect, %{to: "/login"}} = rejected.redirected
      assert rejected.assigns.editing == nil
      assert rejected.assigns.form[:name].value == nil
      assert Repo.get!(Faction, faction.id) == faction
    end
  end
end
