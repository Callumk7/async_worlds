defmodule AsyncWorldsWeb.HttpApiCoverageTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Characters, Journals, PlayerAccess}
  alias AsyncWorlds.Discord.{DebugSessions, PrivateRetrieval}

  @token String.duplicate("a", 32)
  @routes [
    {:get, "/ticks/1/review"},
    {:get, "/ticks/1/review/audits"},
    {:get, "/ticks/1/review/preview"},
    {:post, "/ticks/1/review/edits"},
    {:post, "/ticks/1/publish"},
    {:get, "/ticks/history"},
    {:get, "/ticks/1/history"},
    {:get, "/characters/1/history/result"},
    {:get, "/characters/1/history/submission"},
    {:get, "/deliveries"},
    {:get, "/deliveries/1"},
    {:post, "/deliveries/1/retry"},
    {:get, "/characters/1/journals"},
    {:post, "/characters/1/journals"},
    {:get, "/journals/1"},
    {:delete, "/journals/1"}
  ]

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "22002")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    %{campaign: history_campaign(), base: "/api/campaigns/11001"}
  end

  defp request(method, path, authorized? \\ true) do
    conn = build_conn() |> put_req_header("content-type", "application/json")

    conn =
      if authorized?, do: put_req_header(conn, "authorization", "Bearer " <> @token), else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, "{invalid json")
      :delete -> delete(conn, path, "{invalid json")
    end
  end

  test "all final resource routes authenticate and conceal campaigns before parsing bodies", c do
    for {method, path} <- @routes do
      conn = request(method, c.base <> path, false)
      assert json_response(conn, 401) == %{"error" => %{"code" => "unauthenticated"}}
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert json_response(request(method, "/api/campaigns/11002" <> path), 404) == %{
               "error" => %{"code" => "not_found"}
             }
    end
  end

  test "HTTP saved personal results are identical to Discord shared history", c do
    published = publish_history_quest(c.campaign)
    conn = request(:get, c.base <> "/characters/#{published.character.id}/history/result")
    data = json_response(conn, 200)["data"]
    assert {:ok, text} = PrivateRetrieval.result("11001", "44004")
    assert Enum.join(data["content_chunks"], "") == text
    assert {:ok, text} = PrivateRetrieval.submission("11001", "44004")

    submission =
      json_response(
        request(:get, c.base <> "/characters/#{published.character.id}/history/submission"),
        200
      )["data"]

    assert text =~ submission["choice_label"]
    assert submission["tick_number"] == data["tick_number"]
  end

  test "HTTP DM journal operations preserve player visibility and do not change a Discord persona",
       c do
    {:ok, character} =
      Characters.create_character(c.campaign, "22002", %{
        name: "Subject",
        discord_user_id: "44004"
      })

    {:ok, other} =
      Characters.create_character(c.campaign, "22002", %{name: "Other", discord_user_id: "44005"})

    {:ok, owner} = PlayerAccess.context(c.campaign, "44004")
    {:ok, stranger} = PlayerAccess.context(c.campaign, "44005")
    {:ok, _} = DebugSessions.transition("11001", "22002", {:player, other.id})
    persona = DebugSessions.current(c.campaign)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", "cross-transport")

    created =
      json_response(
        post(
          conn,
          c.base <> "/characters/#{character.id}/journals",
          Jason.encode!(%{title: "Private", body: "For owner"})
        ),
        200
      )["data"]

    id = created["entry_id"]
    assert {:ok, entry} = Journals.get_entry(owner, id)
    assert entry.body == "For owner"
    assert {:error, :not_found} = Journals.get_entry(stranger, id)
    path = c.base <> "/journals/#{id}"
    data = json_response(request(:get, path), 200)["data"]
    assert data["body"] == entry.body

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")

    json_response(
      delete(conn, path, Jason.encode!(%{confirm: true, delete_token: data["delete_token"]})),
      200
    )

    assert {:error, :not_found} = Journals.get_entry(owner, id)
    assert DebugSessions.current(c.campaign) == persona
  end
end
