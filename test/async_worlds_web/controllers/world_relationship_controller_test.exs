defmodule AsyncWorldsWeb.WorldRelationshipControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false

  alias AsyncWorlds.{
    Campaigns,
    Characters,
    Factions,
    LinkHistory,
    Locations,
    Memberships,
    Repo,
    Ticks
  }

  alias AsyncWorlds.Factions.Membership
  alias AsyncWorlds.Locations.Location

  @token String.duplicate("r", 32)
  @base "/api/campaigns/123"

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "456")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    [scope, other] =
      for {guild, dm} <- [{"123", "456"}, {"124", "457"}] do
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild,
            dm_user_id: dm,
            public_channel_id: "789"
          })

        %{campaign: campaign, discord_user_id: dm}
      end

    {:ok, root} = Locations.create_location(scope, %{name: "Region"})
    {:ok, child} = Locations.create_location(scope, %{name: "City"})
    {:ok, foreign} = Locations.create_location(other, %{name: "Foreign"})

    {:ok, character} =
      Characters.create_character(scope.campaign, "456", %{name: "Mira", discord_user_id: "555"})

    {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})

    {:ok, foreign_character} =
      Characters.create_character(other.campaign, "457", %{name: "Other"})

    {:ok, foreign_faction} = Factions.create_faction(other, %{name: "Other guild"})

    %{
      scope: scope,
      other: other,
      root: root,
      child: child,
      foreign: foreign,
      character: character,
      faction: faction,
      foreign_character: foreign_character,
      foreign_faction: foreign_faction
    }
  end

  defp request(method, path, body \\ %{}, token \\ @token) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    case method do
      :get -> get(conn, @base <> path)
      :post -> post(conn, @base <> path, Jason.encode!(body))
      :patch -> patch(conn, @base <> path, Jason.encode!(body))
      :delete -> delete(conn, @base <> path, Jason.encode!(body))
    end
  end

  defp data(conn, status \\ 200), do: json_response(conn, status)["data"]
  defp error(conn, status, code), do: assert(json_response(conn, status)["error"]["code"] == code)

  defp history(c) do
    {:ok, %{items: items}} = LinkHistory.list_changes(c.scope)
    items
  end

  defp join(c, role \\ "Scout") do
    data(
      request(:post, "/memberships", %{
        character_id: to_string(c.character.id),
        faction_id: to_string(c.faction.id),
        role: role
      }),
      201
    )
  end

  test "DM kind, explicit parent transitions and hierarchy reads", c do
    child = "/locations/#{c.child.id}"
    assert data(request(:patch, child, %{kind: "City"}))["kind"] == "City"
    error(request(:patch, child, %{parent_id: c.root.id}), 422, "invalid_parameters")

    assert data(request(:patch, child <> "/parent", %{parent_id: to_string(c.root.id)}))[
             "parent_id"
           ] == to_string(c.root.id)

    assert data(request(:get, child))["kind"] == "City"
    assert Enum.map(data(request(:get, "/locations/roots")), & &1["id"]) == [to_string(c.root.id)]

    assert Enum.map(data(request(:get, "/locations/#{c.root.id}/children")), & &1["id"]) == [
             to_string(c.child.id)
           ]

    assert Enum.map(data(request(:get, child <> "/breadcrumbs")), & &1["id"]) ==
             Enum.map([c.root, c.child], &to_string(&1.id))

    assert length(history(c)) == 1
    data(request(:patch, child <> "/parent", %{parent_id: c.root.id}))
    assert length(history(c)) == 1

    for id <- [c.root.id, c.child.id],
        do: error(request(:delete, "/locations/#{id}"), 409, "location_linked")

    data(request(:patch, child <> "/parent", %{parent_id: nil}))
    data(request(:patch, child <> "/parent", %{parent_id: nil}))
    assert length(history(c)) == 2
    assert data(request(:patch, child, %{kind: " "}))["kind"] == nil
    data(request(:delete, child))
    assert length(history(c)) == 2
  end

  test "membership lifecycle projects only approved fields and preserves history", c do
    joined = join(c)

    assert Enum.sort(Map.keys(joined)) ==
             Enum.sort(~w(id campaign_id character_id faction_id role inserted_at updated_at))

    assert joined["character_id"] == to_string(c.character.id)
    assert joined["faction_id"] == to_string(c.faction.id)

    assert get_resp_header(
             request(:get, "/factions/#{c.faction.id}/memberships"),
             "cache-control"
           ) == ["no-store"]

    for path <- [
          "/factions/#{c.faction.id}/memberships",
          "/characters/#{c.character.id}/memberships"
        ] do
      assert data(request(:get, path)) == [joined]
    end

    error(
      request(:post, "/memberships", %{character_id: c.character.id, faction_id: c.faction.id}),
      422,
      "invalid_parameters"
    )

    path = "/memberships/#{joined["id"]}"
    assert data(request(:patch, path, %{role: "Captain"}))["role"] == "Captain"
    data(request(:patch, path, %{role: "Captain"}))
    data(request(:patch, path))
    assert length(history(c)) == 2
    assert data(request(:patch, path, %{role: nil}))["role"] == nil
    error(request(:delete, "/factions/#{c.faction.id}"), 409, "faction_has_memberships")
    data(request(:delete, path))
    error(request(:delete, path), 404, "not_found")
    error(request(:patch, path, %{role: "No"}), 404, "not_found")
    assert data(request(:get, "/characters/#{c.character.id}/memberships")) == []
    assert join(c, nil)["id"] != joined["id"]
    assert length(history(c)) == 5
    assert Enum.all?(history(c), &(&1.actor_id == "456" and &1.tick_number == 1))
  end

  test "metadata creation, reparenting and bounded hierarchy errors use safe DTOs", c do
    created = data(request(:post, "/locations", %{name: "Other region", kind: "Region"}), 201)
    assert created["kind"] == "Region"
    assert created["parent_id"] == nil

    assert Enum.sort(Map.keys(created)) ==
             Enum.sort(~w(id campaign_id name description kind parent_id inserted_at updated_at))

    path = "/locations/#{c.child.id}/parent"
    data(request(:patch, path, %{parent_id: c.root.id}))
    data(request(:patch, path, %{parent_id: created["id"]}))
    [set, reparent] = history(c)
    assert set.after == reparent.before

    assert reparent.after == %{
             "location_id" => c.child.id,
             "parent_id" => String.to_integer(created["id"])
           }

    assert data(request(:get, "/locations/#{c.root.id}/children")) == []

    assert Enum.map(data(request(:get, "/locations/#{c.child.id}/breadcrumbs")), & &1["id"]) == [
             created["id"],
             to_string(c.child.id)
           ]

    # Defensive traversal failures are an explicit conflict, not an internal error.
    leaf =
      Enum.reduce(1..100, c.root, fn n, parent ->
        %Location{campaign_id: c.scope.campaign.id, parent_id: parent.id}
        |> Location.changeset(%{name: "Node #{n}"})
        |> Repo.insert!()
      end)

    error(request(:get, "/locations/#{leaf.id}/breadcrumbs"), 409, "hierarchy_too_deep")
    error(request(:patch, path, %{parent_id: leaf.id}), 409, "hierarchy_too_deep")
    assert history(c) == [set, reparent]
  end

  test "membership lists are ordered and a bodyless leave retains endpoint history", c do
    first = join(c)
    {:ok, another} = Factions.create_faction(c.scope, %{name: "Another"})

    second =
      data(
        request(:post, "/memberships", %{character_id: c.character.id, faction_id: another.id}),
        201
      )

    assert data(request(:get, "/characters/#{c.character.id}/memberships")) == [first, second]
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> @token)
    assert data(delete(conn, @base <> "/memberships/#{first["id"]}")) == first
    assert data(request(:get, "/characters/#{c.character.id}/memberships")) == [second]
    assert data(request(:get, "/factions/#{c.faction.id}/memberships")) == []
    [joined, _, left] = history(c)
    assert joined.after == left.before
    assert left.after == nil
    assert Repo.get!(Characters.Character, c.character.id) == c.character
  end

  test "cycles, malformed, absent and foreign endpoints never mutate state", c do
    parent = "/locations/#{c.child.id}/parent"
    data(request(:patch, parent, %{parent_id: c.root.id}))
    before = history(c)

    for id <- [c.root.id, c.child.id] do
      error(
        request(:patch, "/locations/#{c.root.id}/parent", %{parent_id: id}),
        409,
        "location_cycle"
      )
    end

    error(request(:patch, parent), 422, "invalid_parameters")

    {:ok, foreign_membership} =
      Memberships.join(c.other, c.foreign_character.id, c.foreign_faction.id)

    for id <- ["bad", "999999999", "9223372036854775808", c.foreign.id] do
      error(request(:patch, parent, %{parent_id: id}), 404, "not_found")

      for suffix <- ["children", "breadcrumbs"] do
        error(request(:get, "/locations/#{id}/#{suffix}"), 404, "not_found")
      end

      error(request(:patch, "/locations/#{id}/parent", %{parent_id: nil}), 404, "not_found")
    end

    for id <- [nil, "bad", "999999999", "9223372036854775808", c.foreign_character.id] do
      error(
        request(:post, "/memberships", %{character_id: id, faction_id: c.faction.id}),
        404,
        "not_found"
      )

      if id, do: error(request(:get, "/characters/#{id}/memberships"), 404, "not_found")
    end

    for id <- [nil, "bad", "999999999", "9223372036854775808", c.foreign_faction.id] do
      error(
        request(:post, "/memberships", %{character_id: c.character.id, faction_id: id}),
        404,
        "not_found"
      )

      if id, do: error(request(:get, "/factions/#{id}/memberships"), 404, "not_found")
    end

    for id <- [%{}, [], true, -1, 0] do
      error(
        request(:post, "/memberships", %{character_id: id, faction_id: c.faction.id}),
        404,
        "not_found"
      )

      error(
        request(:post, "/memberships", %{character_id: c.character.id, faction_id: id}),
        404,
        "not_found"
      )

      error(request(:patch, parent, %{parent_id: id}), 404, "not_found")
    end

    error(request(:post, "/memberships"), 404, "not_found")

    for id <- ["bad", "999999999", "9223372036854775808", foreign_membership.id],
        method <- [:patch, :delete] do
      error(request(method, "/memberships/#{id}"), 404, "not_found")
    end

    assert history(c) == before
    assert Repo.get!(Location, c.child.id).parent_id == c.root.id
    assert Repo.get!(Membership, foreign_membership.id) == foreign_membership
  end

  test "strict request fields, safe validation and authentication for every new route", c do
    joined = join(c)

    routes = [
      {:get, "/locations/roots", %{}},
      {:get, "/locations/#{c.root.id}/children", %{}},
      {:get, "/locations/#{c.child.id}/breadcrumbs", %{}},
      {:patch, "/locations/#{c.child.id}/parent", %{parent_id: c.root.id}},
      {:get, "/characters/#{c.character.id}/memberships", %{}},
      {:get, "/factions/#{c.faction.id}/memberships", %{}},
      {:post, "/memberships", %{character_id: c.character.id, faction_id: c.faction.id}},
      {:patch, "/memberships/#{joined["id"]}", %{role: "Captain"}},
      {:delete, "/memberships/#{joined["id"]}", %{}}
    ]

    before = history(c)

    for {method, path, body} <- routes do
      error(request(method, path, body, "wrong"), 401, "unauthenticated")

      for guild <- ["124", "missing"] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer " <> @token)
          |> put_req_header("content-type", "application/json")

        error(
          Phoenix.ConnTest.dispatch(
            conn,
            @endpoint,
            method,
            "/api/campaigns/#{guild}" <> path,
            "{"
          ),
          404,
          "not_found"
        )
      end

      error(request(method, path <> "?actor_id=999", body), 422, "invalid_parameters")

      if method != :get do
        for field <- ~w(actor_id discord_user_id dm_user_id campaign_id tick_number id) do
          error(request(method, path, Map.put(body, field, "999")), 422, "invalid_parameters")
        end
      end
    end

    error(
      request(:patch, "/memberships/#{joined["id"]}", %{faction_id: c.foreign_faction.id}),
      422,
      "invalid_parameters"
    )

    error(
      request(:patch, "/memberships/#{joined["id"]}", %{character_id: c.foreign_character.id}),
      422,
      "invalid_parameters"
    )

    for role <- [String.duplicate("x", 201), "bad" <> <<0>>, %{}, 42] do
      conn = request(:patch, "/memberships/#{joined["id"]}", %{role: role})
      error(conn, 422, "invalid_parameters")
      assert json_response(conn, 422)["error"]["details"] |> Enum.all?(&(&1["field"] == "role"))
    end

    error(
      request(:patch, "/locations/#{c.child.id}", %{kind: "bad" <> <<0>>}),
      422,
      "invalid_parameters"
    )

    assert history(c) == before

    # Authentication precedes parsing, including on the new mutation routes.
    for {method, path, _} <- routes, method != :get do
      conn = build_conn() |> put_req_header("content-type", "application/json")
      conn = Phoenix.ConnTest.dispatch(conn, @endpoint, method, @base <> path, "{")
      error(conn, 401, "unauthenticated")
    end

    Repo.update!(Ecto.Changeset.change(c.scope.campaign, dm_user_id: "999"))

    for {method, path, body} <- routes do
      error(request(method, path, Map.put(body, "discord_user_id", "999")), 404, "not_found")
    end

    assert Repo.get!(Membership, joined["id"]).role == "Scout"
    assert Repo.get!(Location, c.child.id).parent_id == nil
  end

  test "controllers reauthorize a previously authenticated scope after configuration or DM change",
       c do
    joined = join(c)
    # Model a campaign change between bearer authentication and controller dispatch.
    authenticated =
      build_conn(:get, @base <> "/locations/roots")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> AsyncWorldsWeb.ApiAuth.call([])

    assert authenticated.assigns.current_scope == c.scope

    calls = [
      {AsyncWorldsWeb.LocationController, :roots, %{}, %{}},
      {AsyncWorldsWeb.LocationController, :children, %{"id" => to_string(c.root.id)}, %{}},
      {AsyncWorldsWeb.LocationController, :breadcrumbs, %{"id" => to_string(c.child.id)}, %{}},
      {AsyncWorldsWeb.LocationController, :parent, %{"id" => to_string(c.child.id)},
       %{"parent_id" => c.root.id}},
      {AsyncWorldsWeb.MembershipController, :faction_members, %{"id" => to_string(c.faction.id)},
       %{}},
      {AsyncWorldsWeb.MembershipController, :character_affiliations,
       %{"id" => to_string(c.character.id)}, %{}},
      {AsyncWorldsWeb.MembershipController, :create, %{},
       %{"character_id" => c.character.id, "faction_id" => c.faction.id}},
      {AsyncWorldsWeb.MembershipController, :update, %{"id" => joined["id"]}, %{"role" => "No"}},
      {AsyncWorldsWeb.MembershipController, :delete, %{"id" => joined["id"]}, %{}}
    ]

    for {attrs, status, code} <- [
          {[public_channel_id: "790"], 409, "stale_campaign"},
          {[dm_user_id: "999"], 404, "not_found"}
        ] do
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Campaigns.Campaign, c.scope.campaign.id), attrs)
      )

      for {controller, action, path, body} <- calls do
        conn = %{authenticated | path_params: path, query_params: %{}, body_params: body}
        error(apply(controller, action, [conn, %{}]), status, code)
      end
    end

    assert Repo.get!(Membership, joined["id"]).role == "Scout"
    assert Repo.get!(Location, c.child.id).parent_id == nil
  end

  test "retained history failure rolls back parent, join, role and leave at the HTTP boundary",
       c do
    joined = join(c)
    {:ok, another} = Factions.create_faction(c.scope, %{name: "Another"})
    before = history(c)
    membership = Repo.get!(Membership, joined["id"])

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_http_history() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'history unavailable'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER reject_http_history BEFORE INSERT ON link_changes
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_http_history()
    """)

    for {method, path, body} <- [
          {:patch, "/locations/#{c.child.id}/parent", %{parent_id: c.root.id}},
          {:post, "/memberships", %{character_id: c.character.id, faction_id: another.id}},
          {:patch, "/memberships/#{joined["id"]}", %{role: "Captain"}},
          {:delete, "/memberships/#{joined["id"]}", %{}}
        ] do
      assert_error_sent 500, fn ->
        Repo.transaction(fn -> request(method, path, body) end, mode: :savepoint)
      end

      assert Repo.get!(Location, c.child.id) == c.child
      assert Repo.get!(Membership, membership.id) == membership
      assert Repo.aggregate(Membership, :count) == 1
      assert history(c) == before
    end
  end

  test "HTTP changes retain setup, open and future tick associations without gameplay or projection drift",
       c do
    character = Repo.get!(Characters.Character, c.character.id)
    {:ok, player} = Characters.player_character("123", "555")
    {:ok, member_location} = Locations.get_campaign_location("123", c.child.id)
    {:ok, member_faction} = Factions.get_campaign_faction("123", c.faction.id)
    jobs = Repo.all(Oban.Job)
    deliveries = Repo.all(AsyncWorlds.Deliveries.Delivery)
    joined = join(c)
    parent = "/locations/#{c.child.id}/parent"
    data(request(:patch, parent, %{parent_id: c.root.id}))
    assert Ticks.active_tick(c.scope.campaign.id) == nil
    assert Repo.all(Oban.Job) == jobs
    assert Repo.all(AsyncWorlds.Deliveries.Delivery) == deliveries
    assert Enum.map(history(c), & &1.tick_number) == [1, 1]
    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    data(request(:patch, "/memberships/#{joined["id"]}", %{role: "Captain"}))
    data(request(:patch, parent, %{parent_id: nil}))
    first = history(c)
    assert Enum.map(first, & &1.tick_number) == [1, 1, 1, 1]
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)
    data(request(:delete, "/memberships/#{joined["id"]}"))
    data(request(:patch, parent, %{parent_id: c.root.id}))
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(c.scope.campaign.id, tick.id, snapshot.revision, payload)

    rejoined = join(c, "Leader")
    assert rejoined["id"] != joined["id"]
    data(request(:patch, parent, %{parent_id: nil}))
    before_open = history(c)
    assert Enum.map(Enum.drop(before_open, 4), & &1.tick_number) == [2, 2, 2, 2]
    assert Repo.get!(Characters.Character, c.character.id) == character
    assert Repo.get!(AsyncWorlds.Ticks.Snapshot, snapshot.id) == snapshot
    assert Repo.get!(AsyncWorlds.Ticks.Draft, draft.id) == draft
    assert {:ok, ^player} = Characters.player_character("123", "555")
    assert {:ok, ^member_location} = Locations.get_campaign_location("123", c.child.id)
    assert {:ok, ^member_faction} = Factions.get_campaign_faction("123", c.faction.id)
    {:ok, _} = Ticks.publish_tick(c.scope.campaign.id, tick.id, draft.id)
    {:ok, next} = Ticks.open_tick(c.scope.campaign.id)
    assert next.number == 2
    assert history(c) == before_open
    data(request(:delete, "/memberships/#{rejoined["id"]}"))
    data(request(:delete, "/factions/#{c.faction.id}"))
    data(request(:delete, "/locations/#{c.root.id}"))
    assert length(history(c)) == 9
  end
end
