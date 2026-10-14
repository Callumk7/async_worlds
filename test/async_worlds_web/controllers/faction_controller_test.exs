defmodule AsyncWorldsWeb.FactionControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false

  alias AsyncWorlds.{Campaigns, Factions, Repo}
  alias AsyncWorlds.Factions.Faction

  @token String.duplicate("f", 32)
  @url "/api/campaigns/123/factions"

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

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, faction} =
      Factions.create_faction(%{campaign: campaign, discord_user_id: "456"}, %{name: "Guild"})

    {:ok, foreign} =
      Factions.create_faction(%{campaign: other, discord_user_id: "457"}, %{name: "Foreign"})

    %{campaign: campaign, faction: faction, foreign: foreign}
  end

  defp request(method, url, body \\ %{}, token \\ @token) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    case method do
      :get -> get(conn, url)
      :post -> post(conn, url, Jason.encode!(body))
      :patch -> patch(conn, url, Jason.encode!(body))
      :delete -> delete(conn, url, Jason.encode!(body))
    end
  end

  defp error(conn, status, code),
    do: assert(json_response(conn, status)["error"]["code"] == code)

  test "CRUD returns explicit projections and string IDs", %{faction: faction} do
    conn = request(:get, @url)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => [data]} = json_response(conn, 200)
    assert data["id"] == to_string(faction.id)
    assert data["campaign_id"] == to_string(faction.campaign_id)
    assert data["description"] == nil
    assert is_binary(data["inserted_at"])

    assert Enum.sort(Map.keys(data)) ==
             Enum.sort(~w(id campaign_id name description inserted_at updated_at))

    assert json_response(request(:get, "#{@url}/#{faction.id}"), 200) == %{"data" => data}

    created =
      json_response(request(:post, @url, %{name: "New", description: "Notes"}), 201)["data"]

    updated =
      json_response(
        request(:patch, "#{@url}/#{created["id"]}", %{name: "Renamed", description: nil}),
        200
      )["data"]

    assert updated["name"] == "Renamed"
    assert updated["description"] == nil
    assert json_response(request(:delete, "#{@url}/#{created["id"]}"), 200)["data"] == updated
    error(request(:get, "#{@url}/#{created["id"]}"), 404, "not_found")
  end

  test "DELETE accepts an empty request without a JSON body", %{faction: faction} do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> @token)

    assert json_response(delete(conn, "#{@url}/#{faction.id}"), 200)["data"]["id"] ==
             to_string(faction.id)

    refute Repo.get(Faction, faction.id)
  end

  test "validation is safe and does not partially update", %{faction: faction} do
    conn = request(:patch, "#{@url}/#{faction.id}", %{name: "", description: "Not saved"})
    error(conn, 422, "invalid_parameters")

    assert json_response(conn, 422)["error"]["details"] == [
             %{"field" => "name", "code" => "required"}
           ]

    assert Repo.get!(Faction, faction.id) == faction
    error(request(:post, @url, %{name: String.duplicate("a", 201)}), 422, "invalid_parameters")
    error(request(:post, @url, %{name: "Bad", description: <<0>>}), 422, "invalid_parameters")
  end

  test "rejects query parameters and untrusted fields for all operations", %{faction: faction} do
    url = "#{@url}/#{faction.id}"

    for field <- ~w(id campaign_id guild_id dm_user_id discord_user_id inserted_at) do
      error(request(:post, @url, %{"name" => "No", field => "999"}), 422, "invalid_parameters")
      error(request(:patch, url, %{field => "999"}), 422, "invalid_parameters")
      error(request(:delete, url, %{field => "999"}), 422, "invalid_parameters")
    end

    for {method, path} <- [
          {:get, @url},
          {:get, url},
          {:post, @url},
          {:patch, url},
          {:delete, url}
        ] do
      error(request(method, path <> "?campaign_id=999"), 422, "invalid_parameters")
    end

    error(request(:post, @url, []), 422, "invalid_parameters")
    assert Repo.get!(Faction, faction.id) == faction
  end

  test "conceals foreign and malformed targets and revoked campaigns", c do
    for id <- [c.foreign.id, "bad", "999999", "9223372036854775808"] do
      for method <- [:get, :patch, :delete] do
        error(request(method, "#{@url}/#{id}"), 404, "not_found")
      end
    end

    for guild <- ["124", "999", "bad"] do
      error(request(:get, "/api/campaigns/#{guild}/factions"), 404, "not_found")
    end

    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "458"))
    error(request(:delete, "#{@url}/#{c.faction.id}"), 404, "not_found")
    assert Repo.get!(Faction, c.faction.id) == c.faction
  end

  test "all routes authenticate before body parsing", %{faction: faction} do
    for {method, url} <- [
          {:get, @url},
          {:get, "#{@url}/#{faction.id}"},
          {:post, @url},
          {:patch, "#{@url}/#{faction.id}"},
          {:delete, "#{@url}/#{faction.id}"}
        ] do
      error(request(method, url, %{}, "wrong"), 401, "unauthenticated")
    end

    conn = build_conn() |> put_req_header("content-type", "application/json")
    error(post(conn, @url, "{"), 401, "unauthenticated")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "text/plain")

    error(post(conn, @url, "{}"), 415, "unsupported_media_type")
  end
end
