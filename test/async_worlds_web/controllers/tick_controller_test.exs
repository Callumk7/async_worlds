defmodule AsyncWorldsWeb.TickControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.QuestFixtures

  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Quests, Repo}
  alias AsyncWorlds.DM.Ticks
  alias AsyncWorlds.Quests.Submissions

  @token String.duplicate("t", 32)
  @url "/api/campaigns/123/ticks"

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

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "quest", name: "Quest"}, definition())

    for {name, owner} <- [{"Player", "991"}, {"DM controlled", nil}, {"No quest", "992"}] do
      {:ok, character} =
        Characters.create_character(campaign, "456", %{name: name, discord_user_id: owner})

      if owner != "992", do: Quests.assign(campaign, "456", character.id, revision.id)
    end

    %{campaign: campaign, scope: %{campaign: campaign, discord_user_id: "456"}}
  end

  defp request(method, path, body \\ %{}, headers \\ []) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body))
    end
  end

  defp error(conn, status, code),
    do: assert(json_response(conn, status) == %{"error" => %{"code" => code}})

  test "status, opening and repeated closing use durable lifecycle operations", %{scope: scope} do
    assert json_response(request(:get, @url <> "/status"), 200) == %{"data" => nil}
    conn = request(:post, @url <> "/open")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    tick = json_response(conn, 201)["data"]
    assert tick["status"] == "open"
    assert tick["number"] == 1
    assert is_binary(tick["id"])
    assert tick["campaign_id"] == to_string(scope.campaign.id)
    assert {:ok, _, _} = DateTime.from_iso8601(tick["opened_at"])

    assert Map.keys(tick) |> Enum.sort() ==
             Enum.sort(
               ~w(id campaign_id number status opened_at closed_at reviewed_at published_at)
             )

    assert json_response(request(:get, @url <> "/status"), 200)["data"] == tick
    error(request(:post, @url <> "/open"), 409, "active_tick")

    closed = json_response(request(:post, "#{@url}/#{tick["id"]}/close"), 202)["data"]
    assert closed["status"] == "resolving"
    assert closed["closed_at"] != nil
    assert json_response(request(:post, "#{@url}/#{tick["id"]}/close"), 202)["data"] == closed
    {:ok, jobs} = Ticks.resolution_jobs(scope, String.to_integer(tick["id"]))
    assert length(jobs) == 1
    assert length(Repo.all(AsyncWorlds.Ticks.Snapshot)) == 1
    assert json_response(request(:get, @url <> "/status"), 200)["data"] == closed
  end

  test "readiness includes all subjects, matches domain counts and remains frozen", %{
    scope: scope,
    campaign: campaign
  } do
    {:ok, tick} = Ticks.open_tick(scope)
    path = "#{@url}/#{tick.id}/readiness"
    data = json_response(request(:get, path <> "/roster"), 200)["data"]
    assert data["tick_id"] == to_string(tick.id)
    refute data["frozen"]
    assert data["counts"] == %{"active" => 2, "submitted" => 0, "missing" => 2}
    assert length(data["rows"]) == 3
    assert Enum.any?(data["rows"], &(&1["unassigned"] and &1["state"] == "missing"))
    assert Enum.any?(data["rows"], &(&1["state"] == "no_active_quest"))
    assert Enum.all?(data["rows"], &is_binary(&1["character_id"]))

    assert Map.keys(hd(data["rows"])) |> Enum.sort() ==
             Enum.sort(
               ~w(character_id name discord_user_id unassigned invalidated quest_name node_id state)
             )

    assert json_response(request(:get, path), 200)["data"] == Map.delete(data, "rows")
    {:ok, counts} = Ticks.readiness(scope, tick.id)
    assert Jason.decode!(Jason.encode!(counts)) == data["counts"]

    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")
    assert json_response(request(:get, path), 200)["data"]["counts"]["submitted"] == 1
    request(:post, "#{@url}/#{tick.id}/close") |> json_response(202)
    frozen = json_response(request(:get, path <> "/roster"), 200)["data"]
    assert frozen["frozen"]
    assert frozen["counts"]["submitted"] == 1

    # A historical roster must not mix frozen inputs with live character data.
    character =
      Repo.get_by!(AsyncWorlds.Characters.Character,
        campaign_id: campaign.id,
        discord_user_id: "991"
      )

    character |> Ecto.Changeset.change(name: "Changed later") |> Repo.update!()
    assert json_response(request(:get, path <> "/roster"), 200)["data"] == frozen
  end

  test "generic reminder keys share Discord intents, never resend and do not mutate game state",
       %{scope: scope} do
    {:ok, tick} = Ticks.open_tick(scope)
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "loop")
    before = {Repo.all(AsyncWorlds.Quests.Progression), Repo.all(AsyncWorlds.Quests.Submission)}
    assert {:ok, 1} = Ticks.remind(scope, "100")
    deliveries = Deliveries.list_deliveries(scope.campaign.id)

    for key <- ["http/request-α", "http/request-α", "another-key"] do
      assert json_response(
               request(:post, @url <> "/remind", %{}, [{"idempotency-key", key}]),
               202
             ) == %{"data" => %{"missing" => 1}}

      assert Deliveries.list_deliveries(scope.campaign.id) == deliveries
    end

    assert before ==
             {Repo.all(AsyncWorlds.Quests.Progression), Repo.all(AsyncWorlds.Quests.Submission)}

    {:ok, _} = Ticks.close_tick(scope, tick.id)

    error(
      request(:post, @url <> "/remind", %{}, [{"idempotency-key", "closed"}]),
      409,
      "tick_closed"
    )
  end

  test "strict mutation input and reminder key validation have no side effects", %{scope: scope} do
    error(request(:post, @url <> "/remind"), 428, "precondition_required")

    for key <- ["", " ", String.duplicate("x", 201), "bad" <> <<0>>] do
      error(
        request(:post, @url <> "/remind", %{}, [{"idempotency-key", key}]),
        422,
        "invalid_idempotency_key"
      )

      assert {:error, :invalid_idempotency_key} = Ticks.remind(scope, key)
    end

    error(request(:post, @url <> "/remind", %{}, [{"idempotency-key", "valid"}]), 404, "no_tick")
    error(request(:post, @url <> "/open", %{actor_id: "456"}), 422, "invalid_parameters")
    error(request(:post, @url <> "/open?ignored=true"), 422, "invalid_parameters")

    error(
      request(:post, @url <> "/open", %{}, [{"content-type", "text/plain"}]),
      415,
      "unsupported_media_type"
    )

    error(request(:get, @url <> "/status?ignored=true"), 422, "invalid_parameters")
    assert {:ok, nil} = Ticks.active_tick(scope)
    assert Deliveries.list_deliveries(scope.campaign.id) == []
  end

  test "unauthenticated, forbidden and foreign ticks are concealed", %{scope: scope} do
    error(get(build_conn(), @url <> "/status"), 401, "unauthenticated")

    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "456",
        public_channel_id: "790"
      })

    {:ok, tick} = Ticks.open_tick(%{campaign: foreign, discord_user_id: "456"})

    for id <- [to_string(tick.id), "999999", "bad", "9223372036854775808"] do
      error(request(:get, "#{@url}/#{id}/readiness"), 404, "not_found")
      error(request(:get, "#{@url}/#{id}/readiness/roster"), 404, "not_found")
      error(request(:post, "#{@url}/#{id}/close"), 404, "not_found")
    end

    scope.campaign |> Ecto.Changeset.change(dm_user_id: "457") |> Repo.update!()
    error(request(:get, @url <> "/status"), 404, "not_found")
    error(request(:post, @url <> "/open"), 404, "not_found")
    assert {:error, :unauthorized} = Ticks.readiness_roster(scope, tick.id)
  end

  test "status falls back to latest published tick and published close is rejected", %{
    scope: scope
  } do
    {:ok, tick} = Ticks.open_tick(scope)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(scope, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      AsyncWorlds.Ticks.put_draft(scope.campaign.id, tick.id, snapshot.revision, payload)

    assert json_response(request(:get, @url <> "/status"), 200)["data"]["status"] == "in_review"

    assert json_response(request(:post, "#{@url}/#{tick.id}/close"), 202)["data"]["status"] ==
             "in_review"

    {:ok, _} = Ticks.publish_tick(scope, tick.id, draft.id)
    assert json_response(request(:get, @url <> "/status"), 200)["data"]["status"] == "published"
    error(request(:post, "#{@url}/#{tick.id}/close"), 409, "invalid_transition")
  end
end
