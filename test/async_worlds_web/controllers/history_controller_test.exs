defmodule AsyncWorldsWeb.HistoryControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Characters, Repo}
  @token String.duplicate("h", 32)

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "22002")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    campaign = history_campaign()
    %{campaign: campaign, base: "/api/campaigns/11001"}
  end

  defp request(path),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> @token) |> get(path)

  test "bounded published pages and saved projections exclude delivery internals", c do
    ticks = for n <- 1..21, do: legacy_publication(c.campaign, n)
    data = json_response(request(c.base <> "/ticks/history"), 200)
    assert length(data["data"]) == 20
    assert data["meta"]["next_page"] == 2
    assert json_response(request(c.base <> "/ticks/history?page=2"), 200)["data"] |> length() == 1
    tick = hd(ticks)
    detail = json_response(request(c.base <> "/ticks/#{tick.id}/history"), 200)["data"]
    assert detail["world_news"] == "Legacy approved news 1"
    [message] = detail["sections"]["messages"]["items"]
    assert message["content"] == "Legacy stored message 1"
    refute Map.has_key?(message, "delivery")

    assert json_response(request(c.base <> "/ticks/history?page=0"), 422)["error"]["code"] ==
             "invalid_page"
  end

  test "explicit DM subject selection and fresh campaign isolation", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "22002", %{
        name: "Subject",
        discord_user_id: "44004"
      })

    path = c.base <> "/characters/#{character.id}/history/result"
    assert json_response(request(path), 200)["data"] == nil

    assert json_response(request(c.base <> "/characters/#{character.id}/history/submission"), 200)[
             "data"
           ] == nil

    assert json_response(get(build_conn(), path), 401)["error"]["code"] == "unauthenticated"

    assert json_response(request(String.replace(path, "11001", "11002")), 404)["error"]["code"] ==
             "not_found"

    assert json_response(request(path <> "?actor_id=44004"), 422)["error"]["code"] ==
             "invalid_parameters"

    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "22003"))
    assert json_response(request(path), 404)["error"]["code"] == "not_found"
  end

  test "personal results match saved shared-domain history", c do
    published = publish_history_quest(c.campaign)
    path = c.base <> "/characters/#{published.character.id}/history/result"
    data = json_response(request(path), 200)["data"]
    assert data["tick_id"] == to_string(published.tick.id)
    assert Enum.any?(data["content_chunks"], &String.contains?(&1, "Saved private narration"))

    assert json_response(
             request(c.base <> "/characters/#{published.character.id}/history/submission"),
             200
           )["data"]["choice_id"] == "roll"
  end
end
