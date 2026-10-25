defmodule AsyncWorldsWeb.TensionControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false

  alias AsyncWorlds.{Campaigns, Repo, Ticks}
  alias AsyncWorlds.DM.{Clocks, Tensions}
  alias AsyncWorlds.Tensions.Discussion

  @token String.duplicate("t", 32)
  @base "/api/campaigns/123"
  @url @base <> "/tensions"

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "456")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    scopes =
      for guild <- ["123", "124"] do
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild,
            dm_user_id: "456",
            public_channel_id: "789"
          })

        %{campaign: campaign, discord_user_id: "456"}
      end

    [scope, other] = scopes
    {:ok, tension} = Tensions.create_tension(scope, %{name: "Private", description: "DM prose"})
    {:ok, foreign} = Tensions.create_tension(other, %{name: "Foreign secret"})
    %{scope: scope, other: other, tension: tension, foreign: foreign}
  end

  defp request(method, path, body \\ %{}, authorized? \\ true) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn =
      if authorized?, do: put_req_header(conn, "authorization", "Bearer " <> @token), else: conn

    body = if is_binary(body), do: body, else: Jason.encode!(body)

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, body)
      :patch -> patch(conn, path, body)
    end
  end

  defp error(conn, status, code),
    do: assert(json_response(conn, status)["error"]["code"] == code)

  test "scoped DM reads project private prose, associated IDs and only discussion metadata", c do
    {:ok, clock} = Tensions.create_clock(c.scope, c.tension.id, %{name: "Hidden", segments: 6})
    conn = request(:get, @url)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => [data]} = json_response(conn, 200)

    assert data == %{
             "id" => to_string(c.tension.id),
             "campaign_id" => to_string(c.scope.campaign.id),
             "name" => "Private",
             "description" => "DM prose",
             "audience" => "dm",
             "status" => "ongoing",
             "revision" => 1,
             "inserted_at" => DateTime.to_iso8601(c.tension.inserted_at),
             "updated_at" => DateTime.to_iso8601(c.tension.updated_at)
           }

    detail = json_response(request(:get, "#{@url}/#{c.tension.id}"), 200)["data"]
    assert detail == Map.merge(data, %{"clock_ids" => [to_string(clock.id)], "discussion" => nil})

    Repo.insert!(%Discussion{
      campaign_id: c.scope.campaign.id,
      tension_id: c.tension.id,
      guild_id: "123",
      parent_id: "789",
      name: "Private internal name",
      thread_id: "987",
      status: "ready",
      recovery: %{"entries" => ["private recovery audit"]}
    })

    detail = json_response(request(:get, "#{@url}/#{c.tension.id}"), 200)["data"]

    assert detail["discussion"] == %{
             "status" => "ready",
             "guild_id" => "123",
             "thread_id" => "987"
           }
  end

  test "create and partial edit preserve validation, defaults and revision preconditions", c do
    created = json_response(request(:post, @url, %{name: "Battle"}), 201)["data"]
    assert created["audience"] == "dm"
    assert created["status"] == "ongoing"
    assert created["revision"] == 1
    path = "#{@url}/#{created["id"]}"

    edited =
      json_response(
        request(:patch, path, %{revision: 1, description: "Crossing holds", audience: "public"}),
        200
      )["data"]

    assert edited["name"] == "Battle"
    assert edited["description"] == "Crossing holds"
    assert edited["audience"] == "public"
    assert edited["status"] == "ongoing"
    assert edited["revision"] == 2
    error(request(:patch, path, %{description: "No version"}), 428, "precondition_required")
    error(request(:patch, path, %{revision: 1, name: "Stale"}), 409, "stale_tension")

    for revision <- [-1, 1.5, %{}, "bad"] do
      error(request(:patch, path, %{revision: revision}), 422, "invalid_parameters")
    end

    assert json_response(request(:get, path), 200)["data"]["name"] == "Battle"
    assert {:ok, %{name: "Private"}} = Tensions.get_tension(c.scope, c.tension.id)
  end

  test "invalid prose, audiences, status and identity fields cannot write", c do
    for attrs <- [
          %{},
          %{name: ""},
          %{name: "bad\u0000name"},
          %{name: String.duplicate("é", 101)},
          %{name: "Bad", description: String.duplicate("x", 8001)},
          %{name: "Bad", audience: "player"},
          %{name: "Bad", audience: nil},
          %{name: "Bad", description: %{}},
          []
        ] do
      error(request(:post, @url, attrs), 422, "invalid_parameters")
    end

    for key <- ~w(status campaign_id dm_user_id source id revision) do
      error(request(:post, @url, %{"name" => "No", key => "resolved"}), 422, "invalid_parameters")
    end

    path = "#{@url}/#{c.tension.id}"

    for attrs <- [
          %{revision: 1, name: ""},
          %{revision: 1, audience: nil},
          %{revision: 1, description: "bad\u0000text"},
          %{revision: 1, status: "resolved"},
          %{revision: 1, campaign_id: "999"}
        ] do
      error(request(:patch, path, attrs), 422, "invalid_parameters")
    end

    error(request(:get, @url <> "?audience=public"), 422, "invalid_parameters")
    {400, _, body} = assert_error_sent(400, fn -> request(:post, @url, "{broken") end)
    assert Jason.decode!(body) == %{"error" => %{"code" => "invalid_json"}}
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> @token)
    error(post(conn, @url, %{name: "Not JSON"}), 415, "unsupported_media_type")
    assert {:ok, [tension]} = Tensions.list_tensions(c.scope)
    assert tension == c.tension
  end

  test "all routes authenticate before parsing and conceal unauthorized campaigns", c do
    routes = [
      {:get, "/tensions"},
      {:get, "/tensions/#{c.tension.id}"},
      {:post, "/tensions"},
      {:patch, "/tensions/#{c.tension.id}"},
      {:post, "/tensions/#{c.tension.id}/clocks"},
      {:patch, "/clocks/1/tension"}
    ]

    for {method, suffix} <- routes do
      conn = request(method, @base <> suffix, "{broken", false)
      error(conn, 401, "unauthenticated")
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      error(request(method, "/api/campaigns/999" <> suffix, "{broken"), 404, "not_found")
    end

    for id <- [c.foreign.id, "bad", "999999", "9223372036854775808"] do
      error(request(:get, "#{@url}/#{id}"), 404, "not_found")
      error(request(:patch, "#{@url}/#{id}", %{revision: 1, name: "No"}), 404, "not_found")
      error(request(:post, "#{@url}/#{id}/clocks", %{name: "No", segments: 4}), 404, "not_found")
    end

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    for {method, suffix} <- routes do
      error(request(method, @base <> suffix, "{broken"), 404, "not_found")
    end
  end

  test "clock creation, editing, association and detachment preserve private defaults and snapshots",
       c do
    created =
      json_response(
        request(:post, "#{@url}/#{c.tension.id}/clocks", %{
          name: "Balance",
          segments: 8,
          filled: 3,
          mode: "tug_of_war",
          influences: "River traffic",
          empty_description: "Retreat",
          full_description: "Advance"
        }),
        201
      )["data"]

    assert created["tension_id"] == to_string(c.tension.id)
    assert created["visibility"] == "hidden"
    assert created["association_revision"] == 1
    assert created["mode"] == "tug_of_war"
    assert created["influences"] == "River traffic"
    assert created["empty_description"] == "Retreat"
    assert created["full_description"] == "Advance"
    path = "#{@base}/clocks/#{created["id"]}"

    updated =
      json_response(
        request(:patch, path, %{
          snapshot_token: created["snapshot_token"],
          influences: "Supply lines",
          filled: 99
        }),
        200
      )["data"]

    assert updated["filled"] == 8
    assert updated["influences"] == "Supply lines"
    refute updated["completed"]
    assert updated["empty_description"] == "Retreat"

    error(request(:patch, path <> "/tension", %{tension_id: nil}), 428, "precondition_required")

    error(
      request(:patch, path <> "/tension", %{
        tension_id: nil,
        snapshot_token: created["snapshot_token"]
      }),
      409,
      "stale_clock"
    )

    error(
      request(:patch, path <> "/tension", %{snapshot_token: updated["snapshot_token"]}),
      422,
      "invalid_parameters"
    )

    error(
      request(:patch, path <> "/tension", %{
        tension_id: to_string(c.foreign.id),
        snapshot_token: updated["snapshot_token"]
      }),
      404,
      "not_found"
    )

    detached =
      json_response(
        request(:patch, path <> "/tension", %{
          tension_id: nil,
          snapshot_token: updated["snapshot_token"]
        }),
        200
      )["data"]

    assert detached["tension_id"] == nil
    assert detached["association_revision"] == 2
    assert detached["visibility"] == "hidden"

    linked =
      json_response(
        request(:patch, path <> "/tension", %{
          tension_id: to_string(c.tension.id),
          snapshot_token: detached["snapshot_token"]
        }),
        200
      )["data"]

    assert linked["tension_id"] == to_string(c.tension.id)
    assert linked["association_revision"] == 3
    assert {:ok, audits} = Clocks.list_audits(c.scope)
    assert Enum.all?(audits, &(&1.source == "dm:http:456"))

    {:ok, _} = AsyncWorlds.Clocks.complete_clock(c.scope.campaign.id, created["id"], "engine")
    completed = json_response(request(:get, path), 200)["data"]

    error(
      request(:patch, path <> "/tension", %{
        tension_id: nil,
        snapshot_token: completed["snapshot_token"]
      }),
      409,
      "completed"
    )
  end

  test "invalid nested clock creation is atomic and foreign clock association is concealed", c do
    for attrs <- [
          %{name: "Bad", segments: 5},
          %{name: "Bad", segments: 4, influences: "bad\u0000text"},
          %{name: "Bad", segments: 4, triggers: [nil]},
          %{name: "Bad", segments: 4, tension_id: c.foreign.id}
        ] do
      error(request(:post, "#{@url}/#{c.tension.id}/clocks", attrs), 422, "invalid_parameters")
    end

    assert {:ok, []} = Clocks.list_clocks(c.scope)
    assert {:ok, []} = Clocks.list_audits(c.scope)

    error(
      request(:patch, "#{@base}/clocks/999999/tension", %{tension_id: nil, snapshot_token: "bad"}),
      404,
      "not_found"
    )

    {:ok, foreign_clock} =
      Tensions.create_clock(c.other, c.foreign.id, %{name: "Foreign", segments: 4})

    token = AsyncWorldsWeb.ApiTokens.clock_snapshot(c.other, foreign_clock)

    error(
      request(:patch, "#{@base}/clocks/#{foreign_clock.id}/tension", %{
        tension_id: c.tension.id,
        snapshot_token: token
      }),
      404,
      "not_found"
    )

    assert {:ok, ^foreign_clock} = Clocks.get_clock(c.other, foreign_clock.id)
  end

  test "only tick publication resolves a tension and invalidates pre-publication edits", c do
    path = "#{@url}/#{c.tension.id}"
    error(request(:patch, path, %{revision: 1, status: "resolved"}), 422, "invalid_parameters")
    assert json_response(request(:get, path), 200)["data"]["status"] == "ongoing"

    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)
    {:ok, payload} = Ticks.WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(c.scope.campaign.id, tick.id, snapshot.revision, payload)

    {:ok, %{draft: approved}} =
      Ticks.edit_draft(
        c.scope.campaign.id,
        tick.id,
        draft.id,
        %{
          type: "world",
          key: "settle",
          event: %{
            title: "Settled",
            text: "The crossing holds",
            kind: "resolution",
            audience: "dm",
            changes: [%{entity: "tension", id: c.tension.id, attrs: %{status: "resolved"}}]
          }
        },
        "456",
        "Reviewed resolution"
      )

    assert json_response(request(:get, path), 200)["data"]["status"] == "ongoing"
    {:ok, _} = Ticks.publish_tick(c.scope.campaign.id, tick.id, approved.id)
    resolved = json_response(request(:get, path), 200)["data"]
    assert resolved["status"] == "resolved"
    assert resolved["revision"] == 2
    error(request(:patch, path, %{revision: 1, name: "Stale"}), 409, "stale_tension")
    error(request(:patch, path, %{revision: 2, status: "ongoing"}), 422, "invalid_parameters")
  end

  test "real tick closure locks all writes, leaves reads available and does not mutate frozen state",
       c do
    clock =
      json_response(
        request(:post, "#{@url}/#{c.tension.id}/clocks", %{name: "Pressure", segments: 4}),
        201
      )["data"]

    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)

    for {method, path, attrs} <- [
          {:post, @url, %{name: "Locked"}},
          {:patch, "#{@url}/#{c.tension.id}", %{revision: 1, name: "Locked"}},
          {:post, "#{@url}/#{c.tension.id}/clocks", %{name: "Locked", segments: 4}},
          {:patch, "#{@base}/clocks/#{clock["id"]}/tension",
           %{tension_id: nil, snapshot_token: clock["snapshot_token"]}},
          {:patch, "#{@base}/clocks/#{clock["id"]}",
           %{influences: "Locked", snapshot_token: clock["snapshot_token"]}}
        ] do
      error(request(method, path, attrs), 409, "tick_locked")
    end

    assert json_response(request(:get, @url), 200)

    assert json_response(request(:get, "#{@url}/#{c.tension.id}"), 200)["data"]["name"] ==
             "Private"

    assert {:ok, ^snapshot} = Ticks.fetch_snapshot(c.scope.campaign.id, tick.id)
  end
end
