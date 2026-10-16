defmodule AsyncWorldsWeb.LocationHierarchyLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias AsyncWorlds.{Campaigns, LinkHistory, Locations, Repo, Ticks}
  alias AsyncWorlds.Locations.Location

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    scope = %{campaign: campaign, discord_user_id: "456"}
    %{conn: log_in_dm(conn, campaign), scope: scope}
  end

  test "kind is optional free text and parenting is a separate explicit save", c do
    {:ok, view, _} = live(c.conn, ~p"/locations")
    assert has_element?(view, "#location-parent-hint")
    refute has_element?(view, "#location-parent-form")

    view
    |> form("#location-form", location: %{name: "Harbour", kind: "tidal crossroads"})
    |> render_submit()

    {:ok, [location]} = Locations.list_locations(c.scope)
    assert location.kind == "tidal crossroads"
    assert location.parent_id == nil
    assert has_element?(view, "#location_kind[value='tidal crossroads']")
    assert has_element?(view, "#location-kind-#{location.id}")
    assert has_element?(view, "#location-parent-form")
    refute has_element?(view, "#containment_parent_id option[value='#{location.id}']")

    render_submit(view, "save", %{
      "location" => %{"name" => "Not saved", "kind" => "bad" <> <<0>>}
    })

    assert has_element?(view, "#location-form .text-error")
    assert Repo.get!(Location, location.id).name == "Harbour"
    assert Repo.get!(Location, location.id).kind == "tidal crossroads"
    view |> form("#location-form", location: %{name: "Harbour", kind: ""}) |> render_submit()
    assert Repo.get!(Location, location.id).kind == nil
    refute has_element?(view, "#location-kind-#{location.id}")
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "set, reparent and clear use retained history and actual tick attribution", c do
    root = location(c.scope, "Region")
    other = location(c.scope, "Other region")
    child = location(c.scope, "City")
    {:ok, view, _} = live(c.conn, ~p"/locations")
    edit(view, child)
    parent(view, root.id)
    assert Repo.get!(Location, child.id).parent_id == root.id
    assert has_element?(view, "#containment_parent_id option[value='#{root.id}'][selected]")
    assert has_element?(view, "#breadcrumb-location-#{root.id}")
    assert {:ok, %{items: [first]}} = LinkHistory.list_changes(c.scope)
    assert first.tick_number == 1
    assert first.before == nil
    assert first.after == %{"location_id" => child.id, "parent_id" => root.id}
    assert Ticks.active_tick(c.scope.campaign.id) == nil

    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    # no-op
    parent(view, root.id)
    parent(view, other.id)
    assert Repo.get!(Location, child.id).parent_id == other.id
    refute has_element?(view, "#breadcrumb-location-#{root.id}")
    assert has_element?(view, "#breadcrumb-location-#{other.id}")
    assert {:ok, %{items: [^first, reparented]}} = LinkHistory.list_changes(c.scope)
    assert reparented.tick_number == tick.number
    assert reparented.before == first.after

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)
    parent(view, "")
    # clearing again is also a no-op
    parent(view, "")
    assert Repo.get!(Location, child.id).parent_id == nil
    assert Repo.get!(AsyncWorlds.Ticks.Snapshot, snapshot.id) == snapshot
    assert {:ok, %{items: [cleared]}} = LinkHistory.list_changes(c.scope, tick_number: 2)
    assert cleared.before == reparented.after
    assert cleared.after == nil
    assert has_element?(view, "#containment_parent_id option[value=''][selected]")
    refute has_element?(view, "#breadcrumb-location-#{other.id}")
  end

  test "root, child and breadcrumb navigation remain stable and refresh after moves", c do
    root = location(c.scope, "Region")
    first = location(c.scope, "First city")
    second = location(c.scope, "Second city")
    leaf = location(c.scope, "Tavern")
    {:ok, _} = Locations.set_parent(c.scope, first.id, root.id)
    {:ok, _} = Locations.set_parent(c.scope, second.id, root.id)
    {:ok, _} = Locations.set_parent(c.scope, leaf.id, second.id)
    {:ok, view, _} = live(c.conn, ~p"/locations")
    assert has_element?(view, "#location-children[phx-update=stream]")
    assert has_element?(view, "#child-location-#{root.id}")
    refute has_element?(view, "#child-location-#{leaf.id}")
    view |> element("#child-location-#{root.id}") |> render_click()
    assert has_element?(view, "#location-children > :nth-child(2) #child-location-#{first.id}")
    assert has_element?(view, "#location-children > :nth-child(3) #child-location-#{second.id}")
    view |> element("#child-location-#{second.id}") |> render_click()
    view |> element("#child-location-#{leaf.id}") |> render_click()

    assert has_element?(
             view,
             "#location-breadcrumbs > :nth-child(1) #breadcrumb-location-#{root.id}"
           )

    assert has_element?(
             view,
             "#location-breadcrumbs > :nth-child(2) #breadcrumb-location-#{second.id}"
           )

    assert has_element?(view, "#breadcrumb-location-#{leaf.id}[aria-current=location]")
    assert has_element?(view, "#location-children-empty")
    view |> element("#breadcrumb-location-#{root.id}") |> render_click()
    assert has_element?(view, "#location_name[value=Region]")
    view |> element("#location-roots") |> render_click()
    assert has_element?(view, "#location-parent-hint")
    assert has_element?(view, "#child-location-#{root.id}")
    refute has_element?(view, "#breadcrumb-location-#{root.id}")

    edit(view, first)
    parent(view, "")
    view |> element("#location-roots") |> render_click()
    assert has_element?(view, "#child-location-#{first.id}")
  end

  test "cycle and unavailable parent errors are actionable and cannot leak foreign targets", c do
    root = location(c.scope, "Region")
    child = location(c.scope, "City")
    {:ok, _} = Locations.set_parent(c.scope, child.id, root.id)

    {:ok, foreign_campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    foreign =
      location(%{campaign: foreign_campaign, discord_user_id: "457"}, "Private foreign name")

    {:ok, view, _} = live(c.conn, ~p"/locations")
    edit(view, root)
    refute has_element?(view, "#containment_parent_id option[value='#{foreign.id}']")
    {:ok, before} = LinkHistory.list_changes(c.scope)

    for id <- [root.id, child.id] do
      render_submit(view, "set-parent", %{"containment" => %{"parent_id" => to_string(id)}})
      assert has_element?(view, "#flash-error", "Choose another parent or No parent")
      assert Repo.get!(Location, root.id).parent_id == nil
    end

    for id <- [foreign.id, "bad", "999999999999999999999999999"] do
      render_submit(view, "set-parent", %{"containment" => %{"parent_id" => to_string(id)}})
      assert has_element?(view, "#flash-error", "Parent unavailable")
      assert has_element?(view, "#location-parent-form")
      refute has_element?(view, "#edit-location-#{foreign.id}")
    end

    assert {:ok, ^before} = LinkHistory.list_changes(c.scope)
    assert Repo.get!(Location, root.id).parent_id == nil

    edit(view, child)

    render_submit(view, "set-parent", %{
      "id" => foreign.id,
      "containment" => %{"parent_id" => "", "location_id" => foreign.id}
    })

    assert Repo.get!(Location, child.id).parent_id == nil
    assert Repo.get!(Location, foreign.id) == foreign
  end

  test "reference errors can be resolved with child navigation and explicit parent clearing", c do
    root = location(c.scope, "Region")
    child = location(c.scope, "City")
    {:ok, _} = Locations.set_parent(c.scope, child.id, root.id)
    {:ok, view, _} = live(c.conn, ~p"/locations")
    edit(view, root)
    view |> element("#delete-location") |> render_click()
    assert has_element?(view, "#flash-error", "Clear this location's parent and child links")
    view |> element("#child-location-#{child.id}") |> render_click()
    parent(view, "")
    edit(view, root)
    view |> element("#delete-location") |> render_click()
    refute Repo.get(Location, root.id)
    assert Repo.get!(Location, child.id).parent_id == nil

    assert {:ok, %{items: [set, cleared]}} =
             LinkHistory.list_changes(c.scope, entity: {"location", root.id})

    assert set.after == cleared.before
    assert cleared.after == nil
  end

  test "missing selected locations cannot be recreated by a parent save", c do
    child = location(c.scope, "City")
    {:ok, view, _} = live(c.conn, ~p"/locations")
    edit(view, child)
    {:ok, _} = Locations.delete_location(c.scope, child.id)
    parent(view, "")
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#location-parent-form")
    assert {:ok, []} = Locations.list_locations(c.scope)
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "expired sessions cannot save parent links", c do
    root = location(c.scope, "Region")
    child = location(c.scope, "City")
    {:ok, view, _} = live(c.conn, ~p"/locations")
    edit(view, child)
    Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    parent(view, root.id)
    assert_redirect(view, ~p"/login")
    assert Repo.get!(Location, child.id).parent_id == nil
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "revoked DMs cannot parent or navigate using an open view", c do
    root = location(c.scope, "Region")
    child = location(c.scope, "City")
    {:ok, view, _} = live(c.conn, ~p"/locations")
    edit(view, child)
    Repo.update!(Ecto.Changeset.change(c.scope.campaign, dm_user_id: "555"))
    parent(view, root.id)
    assert_redirect(view, ~p"/login")
    assert Repo.get!(Location, child.id).parent_id == nil
  end

  defp location(scope, name) do
    {:ok, location} = Locations.create_location(scope, %{name: name})
    location
  end

  defp edit(view, location),
    do: view |> element("#edit-location-#{location.id}") |> render_click()

  defp parent(view, id),
    do:
      view
      |> form("#location-parent-form", containment: %{parent_id: to_string(id)})
      |> render_submit()
end
