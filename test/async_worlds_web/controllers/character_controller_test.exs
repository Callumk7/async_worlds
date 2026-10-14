defmodule AsyncWorldsWeb.CharacterControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false

  alias AsyncWorlds.{Campaigns, Characters, Repo}
  alias AsyncWorlds.Characters.Character

  @token String.duplicate("c", 32)
  @url "/api/campaigns/123/characters"
  @flag %{"type" => "boolean", "value" => true, "player_visible" => false}

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

    {:ok, character} = Characters.create_character(campaign, "456", %{name: "Rook"})
    {:ok, foreign} = Characters.create_character(other, "457", %{name: "Other"})
    %{campaign: campaign, character: character, foreign: foreign}
  end

  defp request(method, url, body \\ %{}, token \\ @token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> send_request(method, url, Jason.encode!(body))
  end

  defp send_request(conn, :get, url, _body), do: get(conn, url)
  defp send_request(conn, :post, url, body), do: post(conn, url, body)
  defp send_request(conn, :patch, url, body), do: patch(conn, url, body)
  defp send_request(conn, :put, url, body), do: put(conn, url, body)
  defp send_request(conn, :delete, url, body), do: delete(conn, url, body)

  defp error(conn, status, code),
    do: assert(json_response(conn, status)["error"]["code"] == code)

  test "lists and retrieves only campaign characters with explicit DM projection", %{
    character: character
  } do
    conn = request(:get, @url)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => [data]} = json_response(conn, 200)
    assert data["id"] == to_string(character.id)
    assert data["campaign_id"] == to_string(character.campaign_id)
    assert data["state_version"] == character.state_version
    assert data["discord_user_id"] == nil
    assert data["flags"] == %{}
    assert is_binary(data["inserted_at"])

    assert Enum.sort(Map.keys(data)) ==
             Enum.sort(
               ~w(id campaign_id name discord_user_id flags state_version inserted_at updated_at)
             )

    assert json_response(request(:get, "#{@url}/#{character.id}"), 200) == %{"data" => data}
  end

  test "creates linked and DM-controlled characters and rejects duplicate ownership atomically" do
    attrs = %{
      "name" => "Captain",
      "discord_user_id" => "9007199254740993",
      "flags" => %{"secret" => @flag}
    }

    assert %{"data" => data} = json_response(request(:post, @url, attrs), 201)
    assert data["discord_user_id"] == attrs["discord_user_id"]
    assert data["flags"] == attrs["flags"]
    duplicate = request(:post, @url, attrs)
    error(duplicate, 422, "invalid_parameters")

    assert json_response(duplicate, 422)["error"]["details"] ==
             [%{"field" => "discord_user_id", "code" => "already_taken"}]

    assert Repo.aggregate(Character, :count) == 3

    assert json_response(request(:post, @url, %{"name" => "Unassigned"}), 201)["data"][
             "discord_user_id"
           ] == nil
  end

  test "invalid ownership and conflicting relinks leave the profile unchanged", %{
    campaign: campaign,
    character: character
  } do
    {:ok, _} =
      Characters.create_character(campaign, "456", %{name: "Linked", discord_user_id: "888"})

    for owner <- ["888", "-1", "18446744073709551616", %{}] do
      error(
        request(:patch, "#{@url}/#{character.id}", %{
          "state_version" => character.state_version,
          "name" => "No",
          "discord_user_id" => owner
        }),
        422,
        "invalid_parameters"
      )
    end

    assert Repo.get!(Character, character.id).name == character.name
    assert Repo.get!(Character, character.id).discord_user_id == nil
  end

  test "JSON mutations reject malformed, oversized and non-JSON bodies" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("accept", "application/json")

    {400, _, body} =
      assert_error_sent 400, fn ->
        conn |> put_req_header("content-type", "application/json") |> post(@url, "{")
      end

    assert Jason.decode!(body) == %{"error" => %{"code" => "invalid_json"}}

    error(
      conn |> put_req_header("content-type", "text/plain") |> post(@url, "{}"),
      415,
      "unsupported_media_type"
    )

    {413, _, body} =
      assert_error_sent 413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@url, String.duplicate(" ", 8_000_001))
      end

    assert Jason.decode!(body) == %{"error" => %{"code" => "payload_too_large"}}
  end

  test "updates profile, ownership and flags, then unlinks ownership", %{character: character} do
    attrs = %{
      "state_version" => character.state_version,
      "name" => "New",
      "discord_user_id" => "888",
      "flags" => %{"secret" => @flag}
    }

    data = json_response(request(:patch, "#{@url}/#{character.id}", attrs), 200)["data"]
    assert data["name"] == "New"
    assert data["discord_user_id"] == "888"
    assert data["flags"] == %{"secret" => @flag}
    assert data["state_version"] > character.state_version

    updated =
      json_response(
        request(:patch, "#{@url}/#{character.id}", %{
          "state_version" => data["state_version"],
          "discord_user_id" => nil
        }),
        200
      )["data"]

    assert updated["discord_user_id"] == nil
    assert updated["flags"] == data["flags"]
  end

  test "sets native typed flags, preserves other facts and clears idempotently", %{
    character: character
  } do
    url = "#{@url}/#{character.id}/flags"

    first =
      json_response(
        request(:put, "#{url}/secret", Map.put(@flag, "state_version", character.state_version)),
        200
      )["data"]

    integer = %{
      "type" => "integer",
      "value" => 3,
      "player_visible" => true,
      "state_version" => first["state_version"]
    }

    second = json_response(request(:put, "#{url}/debt", integer), 200)["data"]
    assert second["flags"]["secret"] == @flag
    assert second["flags"]["debt"]["value"] == 3

    third =
      json_response(
        request(:delete, "#{url}/secret", %{"state_version" => second["state_version"]}),
        200
      )["data"]

    refute Map.has_key?(third["flags"], "secret")
    assert third["flags"]["debt"] == second["flags"]["debt"]

    assert json_response(
             request(:delete, "#{url}/secret", %{"state_version" => third["state_version"]}),
             200
           )["data"]["flags"] == third["flags"]
  end

  test "requires valid versions for every edit and rejects stale and ABA state", %{
    campaign: campaign,
    character: character
  } do
    url = "#{@url}/#{character.id}"

    for {method, path, body} <- [
          {:patch, url, %{"name" => "Changed"}},
          {:put, "#{url}/flags/secret", @flag},
          {:delete, "#{url}/flags/secret", %{}}
        ] do
      error(request(method, path, body), 428, "precondition_required")

      for version <- [-1, 1.0, "1x", %{}] do
        error(
          request(method, path, Map.put(body, "state_version", version)),
          422,
          "invalid_parameters"
        )
      end
    end

    {:ok, _} = Characters.update_character(campaign, "456", character.id, %{name: "Changed"})

    {:ok, current} =
      Characters.update_character(campaign, "456", character.id, %{name: character.name})

    for {method, path, body} <- [
          {:patch, url, %{"name" => "Forged"}},
          {:put, "#{url}/flags/secret", @flag},
          {:delete, "#{url}/flags/secret", %{}}
        ] do
      error(
        request(method, path, Map.put(body, "state_version", character.state_version)),
        409,
        "stale_character"
      )
    end

    assert Repo.get!(Character, character.id).state_version == current.state_version
  end

  test "tick locks reject all writes but permit reads", %{
    campaign: campaign,
    character: character
  } do
    Repo.update!(Ecto.Changeset.change(campaign, clock_mutations_locked: true))
    url = "#{@url}/#{character.id}"
    error(request(:post, @url, %{"name" => "Locked"}), 409, "tick_locked")

    for {method, path, body} <- [
          {:patch, url, %{"name" => "Locked"}},
          {:put, "#{url}/flags/secret", @flag},
          {:delete, "#{url}/flags/secret", %{}}
        ] do
      error(
        request(method, path, Map.put(body, "state_version", character.state_version)),
        409,
        "tick_locked"
      )
    end

    assert json_response(request(:get, @url), 200)
    assert json_response(request(:get, url), 200)
    assert Repo.get!(Character, character.id).state_version == character.state_version
  end

  test "conceals foreign, absent and malformed resources and rejects unauthenticated actors", %{
    character: character,
    foreign: foreign,
    campaign: campaign
  } do
    for id <- [foreign.id, "999999", "bad", "9223372036854775808"] do
      error(request(:get, "#{@url}/#{id}"), 404, "not_found")

      error(
        request(:patch, "#{@url}/#{id}", %{"state_version" => 1, "name" => "No"}),
        404,
        "not_found"
      )
    end

    for guild <- ["124", "999", "bad"] do
      error(request(:get, "/api/campaigns/#{guild}/characters"), 404, "not_found")
    end

    error(request(:get, @url, %{}, "wrong"), 401, "unauthenticated")
    assert build_conn() |> get(@url) |> json_response(401)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: campaign.discord_guild_id,
        dm_user_id: "458",
        public_channel_id: "789"
      })

    error(request(:patch, "#{@url}/#{character.id}", %{"state_version" => 1}), 404, "not_found")
  end

  test "rejects untrusted fields and invalid native flags without partial changes", %{
    character: character
  } do
    url = "#{@url}/#{character.id}"

    for field <- ~w(dm_user_id campaign_id id guild_id expected_character updated_at) do
      error(request(:post, @url, %{"name" => "No", field => "999"}), 422, "invalid_parameters")

      error(
        request(:patch, url, %{"state_version" => character.state_version, field => "999"}),
        422,
        "invalid_parameters"
      )
    end

    error(request(:get, @url <> "?dm_user_id=457"), 422, "invalid_parameters")

    for flag <- [
          Map.put(@flag, "value", "true"),
          Map.delete(@flag, "player_visible"),
          Map.put(@flag, "extra", true),
          %{"type" => "integer", "value" => 1.5, "player_visible" => true}
        ] do
      error(
        request(
          :put,
          "#{url}/flags/secret",
          Map.put(flag, "state_version", character.state_version)
        ),
        422,
        if(Map.has_key?(flag, "extra"), do: "invalid_parameters", else: "invalid_flag")
      )

      error(
        request(:patch, url, %{
          "state_version" => character.state_version,
          "name" => "No",
          "flags" => %{"secret" => flag}
        }),
        422,
        "invalid_parameters"
      )
    end

    error(
      request(:put, "#{url}/flags/Bad", Map.put(@flag, "state_version", character.state_version)),
      422,
      "invalid_flag"
    )

    error(request(:post, @url, []), 422, "invalid_parameters")
    assert Repo.get!(Character, character.id).name == character.name
    assert Repo.get!(Character, character.id).state_version == character.state_version
  end
end
