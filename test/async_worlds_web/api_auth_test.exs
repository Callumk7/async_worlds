defmodule AsyncWorldsWeb.ApiAuthTest do
  use AsyncWorldsWeb.ConnCase, async: false
  alias AsyncWorlds.Campaigns
  alias AsyncWorldsWeb.ApiAuth

  @token String.duplicate("t", 32)

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "456")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign}
  end

  defp request(path, header \\ "Bearer " <> @token) do
    Plug.Test.conn(:get, path)
    |> put_req_header("authorization", header)
    |> ApiAuth.call([])
  end

  test "shared scope works for different campaign resources and methods", %{campaign: campaign} do
    for resource <- ["clocks", "characters", "ticks", "quests"],
        method <- [:get, :post, :patch, :delete] do
      conn =
        Plug.Test.conn(method, "/api/campaigns/123/#{resource}")
        |> put_req_header("authorization", "bEaReR " <> @token)
        |> ApiAuth.call([])

      refute conn.halted
      assert conn.assigns.current_scope.campaign.id == campaign.id
      assert conn.assigns.current_scope.discord_user_id == "456"
    end
  end

  test "missing, malformed, wrong and duplicated credentials fail closed" do
    for header <- [
          "",
          "Basic " <> @token,
          "Bearer",
          "Bearer wrong",
          "Bearer " <> @token <> " extra"
        ] do
      conn = request("/api/campaigns/123/clocks", header)
      assert conn.halted
      assert json_response(conn, 401) == %{"error" => %{"code" => "unauthenticated"}}
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      refute Map.has_key?(conn.assigns, :current_scope)
    end

    conn = Plug.Test.conn(:get, "/api/campaigns/123/clocks")

    conn = %{
      conn
      | req_headers: [
          {"authorization", "Bearer " <> @token},
          {"authorization", "Bearer " <> @token}
        ]
    }

    assert conn |> ApiAuth.call([]) |> json_response(401)

    assert Plug.Test.conn(:get, "/api/campaigns/123/clocks")
           |> ApiAuth.call([])
           |> json_response(401)
  end

  test "invalid or absent server configuration fails closed" do
    for config <- [
          [],
          [token: "short", dm_user_id: "456"],
          [token: @token],
          [token: @token, dm_user_id: "invalid"]
        ] do
      Application.put_env(:async_worlds, :dm_api, config)
      assert request("/api/campaigns/123/clocks") |> json_response(401)
    end

    Application.delete_env(:async_worlds, :dm_api)
    assert request("/api/campaigns/123/clocks") |> json_response(401)
  end

  test "missing, invalid and foreign campaigns are indistinguishable" do
    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    for guild <- ["124", "999", "invalid"] do
      conn = request("/api/campaigns/#{guild}/characters")
      assert conn.halted
      assert json_response(conn, 404) == %{"error" => %{"code" => "not_found"}}
    end
  end

  test "ownership and credential changes take effect on the next request" do
    refute request("/api/campaigns/123/ticks").halted

    Application.put_env(:async_worlds, :dm_api,
      token: String.duplicate("n", 32),
      dm_user_id: "456"
    )

    assert request("/api/campaigns/123/ticks") |> json_response(401)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "456")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert request("/api/campaigns/123/ticks") |> json_response(404)
  end

  test "noncampaign API routes receive identity only; browser routes are untouched" do
    conn = request("/api/campaigns")
    assert conn.assigns.current_scope == %{discord_user_id: "456", campaign: nil}
    refute conn.halted
    conn = request("/dashboard", "wrong")
    refute conn.halted
    refute Map.has_key?(conn.assigns, :current_scope)
  end

  test "HTTP scope enters the same actor-aware domain boundary and cannot retain revoked access" do
    conn = request("/api/campaigns/123/clocks")
    scope = conn.assigns.current_scope
    assert {:ok, clock} = AsyncWorlds.DM.Clocks.create_clock(scope, %{name: "HTTP", segments: 4})
    assert {:ok, [audit]} = AsyncWorlds.DM.Clocks.list_audits(scope)
    assert audit.source == "dm:http:456"

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = AsyncWorlds.DM.Clocks.adjust_clock(scope, clock.id, 1)
  end

  test "authentication precedes general JSON parsing, not just import parsing" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/campaigns/123/clocks", "{")

    assert json_response(conn, 401) == %{"error" => %{"code" => "unauthenticated"}}
  end
end
