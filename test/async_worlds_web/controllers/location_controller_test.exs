defmodule AsyncWorldsWeb.LocationControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false

  alias AsyncWorlds.{Campaigns, Locations, Repo}
  alias AsyncWorlds.Locations.Location

  @token String.duplicate("f", 32)
  @url "/api/campaigns/123/locations"

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

    {:ok, location} =
      Locations.create_location(%{campaign: campaign, discord_user_id: "456"}, %{name: "Guild"})

    {:ok, foreign} =
      Locations.create_location(%{campaign: other, discord_user_id: "457"}, %{name: "Foreign"})

    %{campaign: campaign, location: location, foreign: foreign}
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

  test "CRUD returns explicit projections and string IDs", %{location: location} do
    conn = request(:get, @url)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => [data]} = json_response(conn, 200)
    assert data["id"] == to_string(location.id)
    assert data["campaign_id"] == to_string(location.campaign_id)
    assert data["description"] == nil
    assert is_binary(data["inserted_at"])

    assert Enum.sort(Map.keys(data)) ==
             Enum.sort(~w(id campaign_id name description inserted_at updated_at))

    assert json_response(request(:get, "#{@url}/#{location.id}"), 200) == %{"data" => data}

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

  test "DELETE accepts an empty request without a JSON body", %{location: location} do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> @token)

    assert json_response(delete(conn, "#{@url}/#{location.id}"), 200)["data"]["id"] ==
             to_string(location.id)

    refute Repo.get(Location, location.id)
  end

  test "linked locations return an explicit delete conflict", c do
    scope = %{campaign: c.campaign, discord_user_id: "456"}
    {:ok, child} = Locations.create_location(scope, %{name: "Child"})
    {:ok, _} = Locations.set_parent(scope, child.id, c.location.id)

    for id <- [c.location.id, child.id] do
      error(request(:delete, "#{@url}/#{id}"), 409, "location_linked")
      assert Repo.get!(Location, id)
    end
  end

  test "validation is safe and does not partially update", %{location: location} do
    conn = request(:patch, "#{@url}/#{location.id}", %{name: "", description: "Not saved"})
    error(conn, 422, "invalid_parameters")

    assert json_response(conn, 422)["error"]["details"] == [
             %{"field" => "name", "code" => "required"}
           ]

    assert Repo.get!(Location, location.id) == location
    error(request(:post, @url, %{name: String.duplicate("a", 201)}), 422, "invalid_parameters")
    error(request(:post, @url, %{name: "Bad", description: <<0>>}), 422, "invalid_parameters")
  end

  test "rejects query parameters and untrusted fields for all operations", %{location: location} do
    url = "#{@url}/#{location.id}"

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
    assert Repo.get!(Location, location.id) == location
  end

  test "conceals foreign and malformed targets and revoked campaigns", c do
    for id <- [c.foreign.id, "bad", "999999", "9223372036854775808"] do
      for method <- [:get, :patch, :delete] do
        error(request(method, "#{@url}/#{id}"), 404, "not_found")
      end
    end

    for guild <- ["124", "999", "bad"] do
      error(request(:get, "/api/campaigns/#{guild}/locations"), 404, "not_found")
    end

    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "458"))
    error(request(:delete, "#{@url}/#{c.location.id}"), 404, "not_found")
    assert Repo.get!(Location, c.location.id) == c.location
  end

  test "all routes authenticate before body parsing", %{location: location} do
    for {method, url} <- [
          {:get, @url},
          {:get, "#{@url}/#{location.id}"},
          {:post, @url},
          {:patch, "#{@url}/#{location.id}"},
          {:delete, "#{@url}/#{location.id}"}
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
