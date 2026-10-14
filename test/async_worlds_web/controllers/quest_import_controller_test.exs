defmodule AsyncWorldsWeb.QuestImportControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Quests, Repo}
  alias AsyncWorlds.Quests.{Quest, Revision}

  @token String.duplicate("t", 32)
  @url "/api/campaigns/123/quests/import"

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

    %{campaign: campaign, other: other}
  end

  defp document do
    %{
      "version" => 1,
      "quests" => [%{"content_id" => "sample", "name" => "Sample", "definition" => definition()}]
    }
  end

  defp send_json(body, url \\ @url, token \\ @token) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(url, body)
  end

  test "creates, repeats and appends immutable revisions" do
    doc = document()
    assert %{"data" => [created]} = send_json(Jason.encode!(doc)) |> json_response(200)
    assert created["action"] == "created"
    assert created["revision_number"] == 1
    assert %{"data" => [unchanged]} = send_json(Jason.encode!(doc)) |> json_response(200)
    assert unchanged == Map.put(created, "action", "unchanged")
    changed = put_in(doc, ["quests", Access.at(0), "name"], "New name")
    assert %{"data" => [appended]} = send_json(Jason.encode!(changed)) |> json_response(200)
    assert appended["action"] == "appended"
    assert appended["quest_id"] == created["quest_id"]
    assert appended["revision_number"] == 2
    assert Repo.aggregate(Revision, :count) == 2
  end

  test "syntax errors, duplicate keys and invalid content do not write" do
    assert %{"error" => %{"code" => "invalid_json"}} = send_json("{") |> json_response(400)

    assert %{"error" => %{"details" => [%{"path" => "$.version"}]}} =
             send_json(~s({"version":1,"version":1,"quests":[]})) |> json_response(422)

    doc = document()
    invalid = %{hd(doc["quests"]) | "content_id" => "bad", "definition" => %{}}
    body = Map.put(doc, "quests", doc["quests"] ++ [invalid]) |> Jason.encode!()

    assert %{"error" => %{"details" => [%{"path" => path}]}} =
             send_json(body) |> json_response(422)

    assert String.starts_with?(path, "$.quests[1]")
    assert Repo.aggregate(Quest, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
  end

  test "requires configured credential and hides missing or unauthorized campaigns", %{
    campaign: campaign
  } do
    assert send_json("{", @url, "wrong") |> json_response(401)

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(@url, "{")
           |> json_response(401)

    for guild <- ["124", "999", "invalid"] do
      assert send_json("{", "/api/campaigns/#{guild}/quests/import") |> json_response(404) == %{
               "error" => %{"code" => "not_found"}
             }
    end

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: campaign.discord_guild_id,
        dm_user_id: "458",
        public_channel_id: "789"
      })

    assert send_json(Jason.encode!(document())) |> json_response(404)
    Application.delete_env(:async_worlds, :dm_api)
    assert send_json("{") |> json_response(401)
  end

  test "limits raw bodies and requires JSON media type" do
    assert send_json(String.duplicate(" ", 1_048_577)) |> json_response(413)

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> @token)
           |> put_req_header("content-type", "text/plain")
           |> post(@url, "{}")
           |> json_response(415)
  end

  test "accepts the exact size limit and rejects nested duplicate keys" do
    body = Jason.encode!(document())
    padded = body <> String.duplicate(" ", 1_048_576 - byte_size(body))
    assert send_json(padded) |> json_response(200)

    duplicate = String.replace(body, ~s("name":"Sample"), ~s("name":"Sample","name":"Other"))

    assert %{"error" => %{"details" => [%{"path" => "$.quests[0].name"}]}} =
             send_json(duplicate) |> json_response(422)

    assert Repo.aggregate(Revision, :count) == 1
  end

  test "rejects multiple authorization headers and does not accept cookies" do
    conn = build_conn()

    conn = %{
      conn
      | req_headers: [
          {"authorization", "Bearer " <> @token},
          {"authorization", "Bearer " <> @token}
        ]
    }

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(@url, "{}")
           |> json_response(401)

    assert build_conn()
           |> init_test_session(%{web_session_token: @token})
           |> put_req_header("content-type", "application/json")
           |> post(@url, "{}")
           |> json_response(401)
  end

  test "clock aliases are validated against this campaign", %{campaign: campaign, other: other} do
    {:ok, clock} =
      Quests.create_clock(campaign, "456", %{name: "Alarm", segments: 6, visibility: :hidden})

    {:ok, foreign} =
      Quests.create_clock(other, "457", %{name: "Other", segments: 6, visibility: :hidden})

    body = File.read!("priv/quests/harbor.json")
    assert send_json(body, @url <> "?clock_refs[alarm]=#{foreign.id}") |> json_response(422)
    assert send_json(body) |> json_response(422)
    assert send_json(body, @url <> "?clock_refs[alarm]=no") |> json_response(422)
    assert send_json(body, @url <> "?clock_refs[alarm]=#{clock.id}") |> json_response(200)
    assert send_json(body, @url <> "?dm_user_id=457") |> json_response(422)
  end
end
