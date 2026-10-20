defmodule AsyncWorldsWeb.JournalControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Characters, Journals, Repo}
  @token String.duplicate("j", 32)

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "22002")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    campaign = history_campaign()

    {:ok, character} =
      Characters.create_character(campaign, "22002", %{name: "Subject", discord_user_id: "44004"})

    %{
      campaign: campaign,
      character: character,
      scope: %{campaign: campaign, discord_user_id: "22002"},
      base: "/api/campaigns/11001",
      path: "/api/campaigns/11001/characters/#{character.id}/journals"
    }
  end

  defp request(method, path, body \\ %{}, key \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")

    conn = if key, do: put_req_header(conn, "idempotency-key", key), else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body))
      :delete -> delete(conn, path, Jason.encode!(body))
    end
  end

  test "DM create is attributed, private by default and retry safe even after deletion", c do
    attrs = %{title: "Private note", body: "Remember this"}

    assert json_response(request(:post, c.path, attrs), 428)["error"]["code"] ==
             "precondition_required"

    created = json_response(request(:post, c.path, attrs, "create-1"), 200)["data"]
    assert json_response(request(:post, c.path, attrs, "create-1"), 200)["data"] == created

    assert json_response(
             request(:post, c.path, %{title: "Changed", body: "Other"}, "create-1"),
             409
           )["error"]["code"] == "idempotency_conflict"

    path = c.base <> "/journals/#{created["entry_id"]}"
    data = json_response(request(:get, path), 200)["data"]
    assert data["author_id"] == "22002"
    assert data["origin"] == "dm"
    assert data["visibility"] == "private"
    assert data["body"] == "Remember this"

    assert json_response(request(:delete, path, %{delete_token: data["delete_token"]}), 409)[
             "error"
           ]["code"] == "confirmation_required"

    assert json_response(request(:delete, path, %{confirm: true}), 428)["error"]["code"] ==
             "precondition_required"

    body = %{confirm: true, delete_token: data["delete_token"]}
    assert json_response(request(:delete, path, body), 200)["data"]["state"] == "deleted"
    assert json_response(request(:delete, path, body), 200)["data"]["state"] == "already_deleted"

    assert json_response(request(:post, c.path, attrs, "create-1"), 200)["data"]["state"] ==
             "deleted"

    assert json_response(request(:get, path), 404)["error"]["code"] == "not_found"
  end

  test "subject-bound cursor pages preserve ceilings and reject tampering", c do
    for n <- 1..11 do
      {:ok, _} =
        Journals.create_dm_entry(c.scope, c.character.id, "page-#{n}", %{
          title: "Note #{n}",
          body: "Content"
        })
    end

    first = json_response(request(:get, c.path), 200)
    assert length(first["data"]) == 10
    cursor = URI.encode_www_form(first["meta"]["next_cursor"])

    {:ok, _} =
      Journals.create_dm_entry(c.scope, c.character.id, "new", %{title: "New", body: "Content"})

    second = json_response(request(:get, c.path <> "?cursor=#{cursor}"), 200)
    assert length(second["data"]) == 1
    previous = URI.encode_www_form(second["meta"]["previous_cursor"])

    assert json_response(request(:get, c.path <> "?cursor=#{previous}"), 200)["data"] ==
             first["data"]

    assert json_response(request(:get, c.path <> "?cursor=forged"), 422)["error"]["code"] ==
             "invalid_cursor"

    {:ok, other} =
      Characters.create_character(c.campaign, "22002", %{name: "Other", discord_user_id: "44005"})

    assert json_response(
             request(:get, c.base <> "/characters/#{other.id}/journals?cursor=#{cursor}"),
             422
           )["error"]["code"] == "invalid_cursor"
  end

  test "journal cursors expire when campaign configuration changes", c do
    for n <- 1..11 do
      {:ok, _} =
        Journals.create_dm_entry(c.scope, c.character.id, "configuration-#{n}", %{
          title: "Note #{n}",
          body: "Content"
        })
    end

    first = json_response(request(:get, c.path), 200)
    cursor = URI.encode_www_form(first["meta"]["next_cursor"])

    Repo.update!(Ecto.Changeset.change(c.campaign, public_channel_id: "33004"))

    assert json_response(request(:get, c.path <> "?cursor=#{cursor}"), 422)["error"]["code"] ==
             "invalid_cursor"

    assert json_response(request(:get, c.path), 200)["data"] == first["data"]
  end

  test "delete confirmation binds target and campaign configuration; foreign access stays concealed",
       c do
    {:ok, one} =
      Journals.create_dm_entry(c.scope, c.character.id, "one", %{title: "One", body: "Content"})

    {:ok, two} =
      Journals.create_dm_entry(c.scope, c.character.id, "two", %{title: "Two", body: "Content"})

    path = c.base <> "/journals/#{one.entry_id}"
    token = json_response(request(:get, path), 200)["data"]["delete_token"]

    assert json_response(
             request(:delete, c.base <> "/journals/#{two.entry_id}", %{
               confirm: true,
               delete_token: token
             }),
             409
           )["error"]["code"] == "stale_component"

    assert json_response(
             request(:post, c.path, %{title: "No", body: "Content", actor_id: "44004"}, "unsafe"),
             422
           )["error"]["code"] == "invalid_parameters"

    assert json_response(request(:get, String.replace(path, "11001", "11002")), 404)["error"][
             "code"
           ] == "not_found"

    Repo.update!(Ecto.Changeset.change(c.campaign, public_channel_id: "33004"))

    assert json_response(request(:delete, path, %{confirm: true, delete_token: token}), 409)[
             "error"
           ]["code"] == "stale_component"

    Repo.update!(Ecto.Changeset.change(Repo.reload!(c.campaign), dm_user_id: "22003"))
    assert json_response(request(:get, path), 404)["error"]["code"] == "not_found"
  end
end
