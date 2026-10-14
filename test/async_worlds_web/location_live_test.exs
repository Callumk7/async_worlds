defmodule AsyncWorldsWeb.LocationLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias AsyncWorlds.{Campaigns, Locations, Repo}
  alias AsyncWorlds.Locations.Location

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

  test "dashboard navigation leads to location CRUD with streamed list", c do
    {:ok, dashboard, _} = live(c.conn, ~p"/dashboard")
    result = dashboard |> element("#nav-locations") |> render_click()
    {:ok, view, _} = follow_redirect(result, c.conn)
    assert has_element?(view, "#nav-locations[aria-current=page]")
    assert has_element?(view, "#locations-empty")
    assert has_element?(view, "#managed-locations[phx-update=stream]")

    view
    |> form("#location-form", location: %{name: "Guild", description: "First\nSecond"})
    |> render_submit()

    {:ok, [location]} = Locations.list_locations(c.scope)
    assert location.description == "First\nSecond"
    assert has_element?(view, "#edit-location-#{location.id}")
    assert has_element?(view, "#delete-location[data-confirm]")

    view |> element("#new-location") |> render_click()
    refute has_element?(view, "#delete-location")
    view |> element("#edit-location-#{location.id}") |> render_click()
    assert has_element?(view, "#location_name[value=Guild]")

    view
    |> form("#location-form", location: %{name: "Renamed", description: ""})
    |> render_submit()

    assert Repo.get!(Location, location.id).name == "Renamed"
    assert Repo.get!(Location, location.id).description == nil
    view |> element("#delete-location") |> render_click()
    refute has_element?(view, "#edit-location-#{location.id}")
    refute has_element?(view, "#delete-location")
    assert {:ok, []} = Locations.list_locations(c.scope)
  end

  test "invalid input renders field errors without persisting", c do
    {:ok, view, _} = live(c.conn, ~p"/locations")

    for name <- ["", String.duplicate("a", 201), "bad" <> <<0>>] do
      render_submit(view, "save", %{"location" => %{"name" => name}})
      assert has_element?(view, "#location-form .text-error")
      assert {:ok, []} = Locations.list_locations(c.scope)
    end

    view |> form("#location-form", location: %{name: "Valid"}) |> render_submit()
    {:ok, [location]} = Locations.list_locations(c.scope)
    render_submit(view, "save", %{"location" => %{"name" => ""}})
    assert has_element?(view, "#location-form .text-error")
    assert Repo.get!(Location, location.id).name == "Valid"
  end

  test "foreign IDs and supplied ownership cannot grant access; deletion is server-pinned", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Locations.create_location(%{campaign: other, discord_user_id: "457"}, %{name: "Foreign"})

    {:ok, view, _} = live(c.conn, ~p"/locations")
    refute has_element?(view, "#edit-location-#{foreign.id}")
    render_click(view, "edit", %{"id" => foreign.id})
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#delete-location")

    render_submit(view, "save", %{
      "location" => %{
        "name" => "Own",
        "campaign_id" => other.id,
        "id" => foreign.id,
        "discord_user_id" => "457"
      }
    })

    {:ok, [own]} = Locations.list_locations(c.scope)
    assert own.campaign_id == c.campaign.id
    render_click(view, "delete", %{"id" => foreign.id})
    refute Repo.get(Location, own.id)
    assert Repo.get!(Location, foreign.id) == foreign
  end

  test "missing selected targets fail safely rather than creating a replacement", c do
    {:ok, location} = Locations.create_location(c.scope, %{name: "Guild"})
    {:ok, view, _} = live(c.conn, ~p"/locations")
    view |> element("#edit-location-#{location.id}") |> render_click()
    {:ok, _} = Locations.delete_location(c.scope, location.id)
    view |> form("#location-form", location: %{name: "No"}) |> render_submit()
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#delete-location")
    assert {:ok, []} = Locations.list_locations(c.scope)
  end

  test "unauthenticated sessions are redirected and expired sessions cannot write", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/locations")
    {:ok, view, _} = live(c.conn, ~p"/locations")
    Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    render_submit(view, "save", %{"location" => %{"name" => "No"}})
    assert_redirect(view, ~p"/login")
    assert {:ok, []} = Locations.list_locations(c.scope)
  end

  test "DM configuration changes revoke an open editor", c do
    {:ok, location} = Locations.create_location(c.scope, %{name: "Guild"})
    {:ok, view, _} = live(c.conn, ~p"/locations")
    view |> element("#edit-location-#{location.id}") |> render_click()
    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "555"))
    view |> element("#delete-location") |> render_click()
    assert_redirect(view, ~p"/login")
    assert Repo.get!(Location, location.id) == location
  end

  test "authorization lost after the event hook clears private editor state", c do
    {:ok, location} = Locations.create_location(c.scope, %{name: "Private"})

    socket =
      %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
        assigns: %{__changed__: %{}, flash: %{}}
      }
      |> Phoenix.Component.assign(:current_scope, c.scope)

    {:ok, socket} = AsyncWorldsWeb.LocationLive.mount(%{}, %{}, socket)

    {:noreply, socket} =
      AsyncWorldsWeb.LocationLive.handle_event("edit", %{"id" => location.id}, socket)

    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "555"))

    for {event, params} <- [
          {"new", %{}},
          {"delete", %{}},
          {"save", %{"location" => %{"name" => "No"}}}
        ] do
      {:noreply, rejected} = AsyncWorldsWeb.LocationLive.handle_event(event, params, socket)
      assert {:redirect, %{to: "/login"}} = rejected.redirected
      assert rejected.assigns.editing == nil
      assert rejected.assigns.form[:name].value == nil
      assert Repo.get!(Location, location.id) == location
    end
  end
end
