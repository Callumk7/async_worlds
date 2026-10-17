defmodule AsyncWorldsWeb.WorldRelationshipLifecycleTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AsyncWorlds.{Characters, Factions, LinkHistory, Locations, Repo, Ticks}
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter}
  alias AsyncWorlds.Ticks.WorldResolver

  @token String.duplicate("w", 32)
  @protected [
    Characters.Character,
    AsyncWorlds.Quests.Quest,
    AsyncWorlds.Quests.Revision,
    AsyncWorlds.Quests.Progression,
    AsyncWorlds.Quests.Submission,
    AsyncWorlds.Ticks.Snapshot,
    AsyncWorlds.Ticks.Draft,
    AsyncWorlds.Ticks.Publication,
    AsyncWorlds.Ticks.ReviewEdit,
    AsyncWorlds.Ticks.Roll,
    AsyncWorlds.Deliveries.Delivery,
    Oban.Job
  ]

  setup %{conn: conn} do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "456")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    start_supervised!({FakeAdapter, owner: self()})
    campaign = AsyncWorlds.HistoryFixtures.history_campaign("123", "456")
    scope = %{campaign: campaign, discord_user_id: "456"}
    {:ok, faction} = Factions.create_faction(scope, %{name: "Guild", description: "Public notes"})
    {:ok, root} = Locations.create_location(scope, %{name: "Region"})
    {:ok, other} = Locations.create_location(scope, %{name: "Other region"})
    {:ok, child} = Locations.create_location(scope, %{name: "City", description: "Public city"})

    %{
      conn: log_in_dm(conn, campaign),
      campaign: campaign,
      scope: scope,
      faction: faction,
      root: root,
      other: other,
      child: child
    }
  end

  test "mounted dashboards and bearer HTTP share a retained lifecycle across real ticks", c do
    fixture = AsyncWorlds.HistoryFixtures.publish_history_quest(c.campaign)
    character = Repo.get!(Characters.Character, fixture.character.id)
    assert map_size(character.flags) > 0
    assert character.discord_user_id == "44004"

    for schema <- @protected,
        do: assert(Repo.all(schema) != [], "empty fixture: #{inspect(schema)}")

    {:ok, factions, _} = live(c.conn, ~p"/factions")
    factions |> element("#edit-faction-#{c.faction.id}") |> render_click()
    {:ok, locations, _} = live(c.conn, ~p"/locations")
    edit_location(locations, c.child)
    baseline = protected_rows()
    projections = discord_responses(c, character)

    factions
    |> form("#membership-join-form", membership: %{target_id: character.id, role: ""})
    |> render_submit()

    [joined] = api(:get, "/characters/#{character.id}/memberships")
    assert joined["role"] == nil
    api(:patch, "/memberships/#{joined["id"]}", %{role: "Secret captain"})
    # Refresh the mounted panel through a real event, not a second independent helper.
    factions |> element("#edit-faction-#{c.faction.id}") |> render_click()
    assert has_element?(factions, "#membership-role-#{joined["id"]}[value='Secret captain']")
    parent(locations, c.root.id)
    assert api(:get, "/locations/#{c.child.id}")["parent_id"] == to_string(c.root.id)
    assert protected_rows() == baseline
    assert Enum.map(history(c), & &1.tick_number) == [2, 2, 2]
    assert Repo.get_by(AsyncWorlds.Ticks.Tick, campaign_id: c.campaign.id, number: 2) == nil

    before_open = history(c)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    assert tick.number == 2
    assert history(c) == before_open
    baseline = protected_rows()
    api(:patch, "/locations/#{c.child.id}/parent", %{parent_id: c.other.id})
    edit_location(locations, c.child)
    assert has_element?(locations, "#breadcrumb-location-#{c.other.id}")
    factions |> element("#membership-leave-#{joined["id"]}") |> render_click()
    assert api(:get, "/characters/#{character.id}/memberships") == []
    assert protected_rows() == baseline

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    assert Ticks.active_tick(c.campaign.id).status == :resolving
    baseline = protected_rows()

    rejoined =
      api(:post, "/memberships", %{character_id: character.id, faction_id: c.faction.id}, 201)

    assert rejoined["id"] != joined["id"]
    parent(locations, "")
    assert protected_rows() == baseline
    assert Repo.get_by(AsyncWorlds.Ticks.Tick, campaign_id: c.campaign.id, number: 3) == nil
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    assert Ticks.active_tick(c.campaign.id).status == :in_review
    assert Repo.get_by(AsyncWorlds.Ticks.Tick, campaign_id: c.campaign.id, number: 3) == nil
    baseline = protected_rows()
    factions |> element("#edit-faction-#{c.faction.id}") |> render_click()

    factions
    |> form("#membership-role-form-#{rejoined["id"]}", membership: %{role: "Returned"})
    |> render_submit()

    parent(locations, c.root.id)
    assert protected_rows() == baseline
    assert discord_responses(c, character) == projections

    changes = history(c)
    assert Enum.map(changes, & &1.tick_number) == [2, 2, 2, 2, 2, 3, 3, 3, 3]
    assert Enum.map(changes, & &1.id) == Enum.sort(Enum.map(changes, & &1.id))
    [join, role, set, move, leave, rejoin, clear, returned, reset] = changes
    assert join.before == nil
    assert join.after == membership_state(c, character, nil)
    assert role.before == join.after
    assert role.after == membership_state(c, character, "Secret captain")
    assert leave.before == role.after and leave.after == nil
    assert rejoin.before == nil and rejoin.after == join.after
    assert returned.before == rejoin.after
    assert returned.after == membership_state(c, character, "Returned")
    assert set.before == nil
    assert set.after == %{"location_id" => c.child.id, "parent_id" => c.root.id}
    assert move.before == set.after
    assert move.after == %{"location_id" => c.child.id, "parent_id" => c.other.id}
    assert clear.before == move.after and clear.after == nil
    assert reset.before == nil and reset.after == set.after
    assert Enum.all?(changes, &(&1.actor_id == "456" and &1.inserted_at != nil))
    assert join.link_id == leave.link_id
    assert rejoin.link_id != join.link_id
    assert role.entity_refs == join.entity_refs

    assert {:ok, %{items: character_changes}} =
             LinkHistory.list_changes(c.scope, entity: {"character", character.id})

    assert character_changes == [join, role, leave, rejoin, returned]

    assert {:ok, %{items: old_parent_changes}} =
             LinkHistory.list_changes(c.scope, entity: {"location", c.other.id})

    assert old_parent_changes == [move, clear]

    assert MapSet.new(move.entity_refs["location"]) ==
             MapSet.new([c.child.id, c.root.id, c.other.id])

    assert join.entity_refs == %{"character" => [character.id], "faction" => [c.faction.id]}

    # Invalid and no-op writes in both interfaces leave live and retained rows alone.
    live_rows = relationship_rows()
    parent(locations, c.root.id)
    api(:patch, "/memberships/#{rejoined["id"]}", %{role: "Returned"})
    api(:patch, "/locations/#{c.root.id}/parent", %{parent_id: c.child.id}, 409)

    render_submit(factions, "membership_role", %{
      "id" => rejoined["id"],
      "membership" => %{"role" => String.duplicate("x", 201)}
    })

    assert has_element?(factions, "#membership-role-form-#{rejoined["id"]} .text-error")
    assert history(c) == changes
    assert relationship_rows() == live_rows
    assert protected_rows() == baseline
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    published = protected_rows()
    api(:patch, "/locations/#{c.child.id}", %{kind: "Secret district"})
    api(:patch, "/memberships/#{rejoined["id"]}", %{role: nil})
    assert protected_rows() == published
    retained = history(c)
    assert Enum.map(Enum.drop(retained, length(changes)), & &1.tick_number) == [3]
    assert Repo.get_by(AsyncWorlds.Ticks.Tick, campaign_id: c.campaign.id, number: 3) == nil
    {:ok, next} = Ticks.open_tick(c.campaign.id)
    assert next.number == 3
    assert history(c) == retained
    assert discord_responses(c, character) == projections
  end

  test "setup writes do not open a tick and both live sessions and HTTP freshly reject revoked DMs",
       c do
    {:ok, character} = Characters.create_character(c.campaign, "456", %{name: "Hero"})
    {:ok, view, _} = live(c.conn, ~p"/characters")
    view |> element("#edit-character-#{character.id}") |> render_click()

    view
    |> form("#membership-join-form", membership: %{target_id: c.faction.id, role: ""})
    |> render_submit()

    [joined] = api(:get, "/factions/#{c.faction.id}/memberships")
    assert [%{tick_number: 1}] = history(c)
    assert Ticks.active_tick(c.campaign.id) == nil
    before = history(c)
    baseline = protected_rows()
    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "999"))
    api(:patch, "/memberships/#{joined["id"]}", %{role: "No"}, 404)
    view |> element("#membership-leave-#{joined["id"]}") |> render_click()
    assert_redirect(view, ~p"/login")
    assert Repo.get!(AsyncWorlds.Factions.Membership, joined["id"]).role == nil
    assert protected_rows() == baseline
    assert Repo.all(AsyncWorlds.LinkHistory.Change) == before
  end

  test "cross-interface endpoint scoping rejects foreign IDs without touching either campaign",
       c do
    foreign = AsyncWorlds.HistoryFixtures.history_campaign("124", "457")
    foreign_scope = %{campaign: foreign, discord_user_id: "457"}

    {:ok, foreign_location} =
      Locations.create_location(foreign_scope, %{name: "Private foreign place"})

    {:ok, foreign_faction} =
      Factions.create_faction(foreign_scope, %{name: "Private foreign guild"})

    {:ok, character} = Characters.create_character(c.campaign, "456", %{name: "Hero"})
    {:ok, view, _} = live(c.conn, ~p"/characters")
    view |> element("#edit-character-#{character.id}") |> render_click()
    refute has_element?(view, "#membership-target option[value='#{foreign_faction.id}']")
    api(:post, "/memberships", %{character_id: character.id, faction_id: foreign_faction.id}, 404)

    render_submit(view, "membership_join", %{"membership" => %{"target_id" => foreign_faction.id}})

    assert has_element?(view, "#flash-error")
    {:ok, locations, _} = live(c.conn, ~p"/locations")
    edit_location(locations, c.child)
    api(:patch, "/locations/#{c.child.id}/parent", %{parent_id: foreign_location.id}, 404)

    render_submit(locations, "set-parent", %{
      "containment" => %{"parent_id" => foreign_location.id}
    })

    assert has_element?(locations, "#flash-error")
    assert Repo.get!(AsyncWorlds.Locations.Location, c.child.id) == c.child
    assert Repo.get!(AsyncWorlds.Locations.Location, foreign_location.id) == foreign_location
    assert Repo.all(AsyncWorlds.Factions.Membership) == []
    assert Repo.all(AsyncWorlds.LinkHistory.Change) == []
    # Valid writes still need no primary designation or revision precondition.
    joined =
      api(:post, "/memberships", %{character_id: character.id, faction_id: c.faction.id}, 201)

    view |> element("#edit-character-#{character.id}") |> render_click()
    assert has_element?(view, "#memberships-#{joined["id"]}")
    assert joined["role"] == nil
    refute has_element?(view, "[name*=primary]")
  end

  test "failed retained writes roll back at the independent persistence boundary" do
    # Production calls use a disposable NON-sandbox database, not ConnCase's
    # ordinary sandbox. No test transaction/savepoint encloses these requests.
    config =
      Repo.config()
      |> Keyword.drop([:name, :pool])
      |> Keyword.merge(
        database: "eng88_atomic_#{System.unique_integer([:positive])}",
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> assert :ok = Ecto.Adapters.Postgres.storage_down(config) end)
    isolated = AsyncWorlds.WorldMigrationRepo
    start_supervised!({isolated, config})

    Ecto.Migrator.run(isolated, Application.app_dir(:async_worlds, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    previous_repo = Repo.put_dynamic_repo(isolated)

    try do
      campaign = AsyncWorlds.HistoryFixtures.history_campaign("123", "456")
      scope = %{campaign: campaign, discord_user_id: "456"}
      {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})
      {:ok, another} = Factions.create_faction(scope, %{name: "Another"})
      {:ok, root} = Locations.create_location(scope, %{name: "Region"})
      {:ok, child} = Locations.create_location(scope, %{name: "City"})
      {:ok, character} = Characters.create_character(campaign, "456", %{name: "Hero"})

      joined =
        api(
          :post,
          "/memberships",
          %{
            character_id: character.id,
            faction_id: faction.id,
            role: "Original"
          },
          201
        )

      # This independent physical connection sees committed rows only, proving
      # that even fixture writes are not enclosed in a sandbox transaction.
      observer = start_supervised!({Postgrex, Keyword.drop(config, [:pool, :pool_size])})
      baseline = persisted_rows(observer)
      assert length(baseline["faction_memberships"]) == 1
      assert length(baseline["link_changes"]) == 1
      refute Repo.in_transaction?()

      Repo.query!("""
      CREATE FUNCTION reject_lifecycle_history() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'history unavailable'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER reject_lifecycle_history BEFORE INSERT ON link_changes
      FOR EACH ROW EXECUTE FUNCTION reject_lifecycle_history()
      """)

      for {method, path, body} <- [
            {:patch, "/locations/#{child.id}/parent", %{parent_id: root.id}},
            {:post, "/memberships", %{character_id: character.id, faction_id: another.id}},
            {:patch, "/memberships/#{joined["id"]}", %{role: "Changed"}},
            {:delete, "/memberships/#{joined["id"]}", %{}}
          ] do
        refute Repo.in_transaction?()
        assert_error_sent 500, fn -> api(method, path, body) end
        refute Repo.in_transaction?()

        assert persisted_rows(observer) == baseline,
               "persisted state changed after #{method} #{path}"

        assert api(:get, "/characters/#{character.id}/memberships") == [joined]
        assert api(:get, "/locations/#{child.id}")["parent_id"] == nil
      end
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp persisted_rows(observer) do
    tables =
      ["faction_memberships", "locations", "link_changes"] ++
        Enum.map(@protected, & &1.__schema__(:source))

    Map.new(tables, fn table ->
      %{rows: rows} =
        Postgrex.query!(observer, "SELECT row_to_json(t) FROM #{table} t ORDER BY id", [])

      {table, rows}
    end)
  end

  defp relationship_rows do
    Map.new([AsyncWorlds.Factions.Membership, Locations.Location], fn schema ->
      {schema, Enum.sort_by(Repo.all(schema), & &1.id)}
    end)
  end

  defp protected_rows do
    Map.new(@protected, fn schema -> {schema, Enum.sort_by(Repo.all(schema), & &1.id)} end)
  end

  defp history(c) do
    {:ok, %{items: rows}} = LinkHistory.list_changes(c.scope)
    rows
  end

  defp membership_state(c, character, role),
    do: %{"character_id" => character.id, "faction_id" => c.faction.id, "role" => role}

  defp edit_location(view, location),
    do: view |> element("#edit-location-#{location.id}") |> render_click()

  defp parent(view, id),
    do:
      view
      |> form("#location-parent-form", containment: %{parent_id: to_string(id)})
      |> render_submit()

  defp api(method, path, body \\ %{}, status \\ 200) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")

    conn =
      Phoenix.ConnTest.dispatch(
        conn,
        @endpoint,
        method,
        "/api/campaigns/123" <> path,
        Jason.encode!(body)
      )

    response = json_response(conn, status)
    if status < 400, do: response["data"], else: response["error"]
  end

  defp discord_responses(c, character) do
    commands =
      [%{name: "character"}] ++
        for {name, id} <- [{"faction", c.faction.id}, {"location", c.child.id}],
            operation <- ["list", "show"] do
          options =
            if operation == "show", do: [%{name: name, type: 3, value: to_string(id)}], else: []

          %{name: name, options: [%{name: operation, type: 1, options: options}]}
        end

    Enum.map(commands, fn data ->
      interaction = %{
        type: 2,
        id: System.unique_integer([:positive]),
        application_id: 111,
        guild_id: 123,
        member: %{user_id: String.to_integer(character.discord_user_id)},
        token: "test-only",
        data: data
      }

      assert {:ok, content} =
               Dispatcher.handle(interaction,
                 adapter: FakeAdapter,
                 guild_id: "123",
                 application_id: "111"
               )

      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, {_, ^content}}
      refute content =~ "Secret"
      content
    end)
  end
end
