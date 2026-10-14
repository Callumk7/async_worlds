defmodule AsyncWorldsWeb.QuestAuthoringControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.QuestFixtures

  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.{Progression, Quest, Revision, WorkingCopy}

  @token String.duplicate("q", 32)
  @url "/api/campaigns/123/quests"
  @copies @url <> "/working-copies"

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
        dm_user_id: "456",
        public_channel_id: "790"
      })

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Released", content_id: "released"},
        definition()
      )

    {:ok, foreign_revision} =
      Quests.create_quest(other, "456", %{name: "Foreign", content_id: "foreign"}, definition())

    {:ok, foreign_work} = Quests.create_working_copy(other, "456", foreign_revision.id)
    {:ok, work} = Quests.create_working_copy(campaign, "456", revision.id)

    %{
      campaign: campaign,
      other: other,
      revision: revision,
      work: work,
      foreign_revision: foreign_revision,
      foreign_work: foreign_work
    }
  end

  defp request(method, path, body \\ %{}) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    encoded = Jason.encode!(body)

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, encoded)
      :put -> put(conn, path, encoded)
    end
  end

  defp error(conn, status, code), do: assert(json_response(conn, status)["error"]["code"] == code)

  defp attrs(work),
    do: %{"name" => work.name, "content_id" => work.content_id, "definition" => work.definition}

  defp edit(work), do: Map.put(attrs(work), "version", work.version)

  test "library and collection reads are campaign scoped summaries without source snapshots", %{
    work: work,
    revision: revision
  } do
    conn = request(:get, @url)
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert %{"data" => %{"working_copies" => [draft], "revisions" => [released]}} =
             json_response(conn, 200)

    assert draft["id"] == to_string(work.id)
    assert draft["quest_id"] == to_string(work.quest_id)
    assert draft["base_revision_id"] == to_string(revision.id)
    assert draft["version"] == 1
    refute Map.has_key?(draft, "definition")
    refute Map.has_key?(draft, "source_definition")

    assert released == %{
             "id" => to_string(revision.id),
             "name" => "Released",
             "content_id" => "released",
             "number" => 1
           }

    assert json_response(request(:get, @copies), 200) == %{"data" => [draft]}
    assert json_response(request(:get, @url <> "/revisions"), 200) == %{"data" => [released]}
  end

  test "revision and working-copy retrieval preserve full authoring content with explicit IDs", %{
    work: work,
    revision: revision
  } do
    assert %{"data" => data} = json_response(request(:get, "#{@copies}/#{work.id}"), 200)
    assert data["definition"] == work.definition

    assert Enum.sort(Map.keys(data)) ==
             Enum.sort(
               ~w(id campaign_id quest_id base_revision_id name content_id version inserted_at updated_at definition)
             )

    assert %{"data" => data} =
             json_response(request(:get, "#{@url}/revisions/#{revision.id}"), 200)

    assert data == %{
             "id" => to_string(revision.id),
             "campaign_id" => to_string(revision.campaign_id),
             "quest_id" => to_string(revision.quest_id),
             "number" => 1,
             "definition" => revision.definition
           }
  end

  test "creates blank drafts and independent working copies from released revisions", %{
    revision: revision
  } do
    data = json_response(request(:post, @copies, %{}), 201)["data"]
    assert data["quest_id"] == nil
    assert data["base_revision_id"] == nil
    assert data["version"] == 1
    assert data["name"] == ""
    assert String.starts_with?(data["content_id"], "quest_")

    seeded =
      json_response(request(:post, @copies, %{"revision_id" => to_string(revision.id)}), 201)[
        "data"
      ]

    assert seeded["definition"] == revision.definition
    assert seeded["base_revision_id"] == to_string(revision.id)
    assert seeded["id"] != data["id"]
    assert Repo.aggregate(Revision, :count) == 2
  end

  test "save accepts incomplete content and does not release or change source", %{
    campaign: campaign
  } do
    {:ok, work} = Quests.create_working_copy(campaign, "456")
    body = edit(work) |> Map.put("name", "Incomplete")
    data = json_response(request(:put, "#{@copies}/#{work.id}", body), 200)["data"]
    assert data["name"] == "Incomplete"
    assert data["version"] == 2
    assert data["definition"] == work.definition
    assert Repo.get!(WorkingCopy, work.id).source_definition == work.source_definition
    assert Repo.aggregate(Revision, :count) == 2
    assert Repo.aggregate(Quest, :count) == 2
  end

  test "save and release require versions and full snapshots, not latest-state substitution", %{
    work: work
  } do
    for {method, suffix} <- [{:put, ""}, {:post, "/release"}] do
      path = "#{@copies}/#{work.id}#{suffix}"
      error(request(method, path, attrs(work)), 428, "precondition_required")

      for version <- [1.0, "1x", -1, %{}] do
        error(
          request(method, path, Map.put(attrs(work), "version", version)),
          422,
          "invalid_parameters"
        )
      end

      error(
        request(method, path, %{"version" => work.version, "name" => "Partial"}),
        422,
        "invalid_parameters"
      )
    end

    assert Repo.get!(WorkingCopy, work.id) == work
  end

  test "release appends immutable revisions without repinning progression or changing frozen ticks",
       %{campaign: campaign, work: work, revision: original} do
    {:ok, character} = Characters.create_character(campaign, "456", %{name: "Rook"})
    {:ok, progression} = Quests.assign(campaign, "456", character.id, original.id)
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, _} = Ticks.close_tick(campaign.id, tick.id)
    frozen = Repo.get!(AsyncWorlds.Ticks.Tick, tick.id)
    changed = put_in(work.definition, ["nodes", Access.at(0), "text"], "Changed")
    body = edit(work) |> Map.put("definition", changed) |> Map.put("name", "New title")
    data = json_response(request(:post, "#{@copies}/#{work.id}/release", body), 200)["data"]
    assert data["revision"]["number"] == 2
    assert data["revision"]["definition"] == changed
    assert data["working_copy"]["version"] == work.version + 1
    assert data["working_copy"]["base_revision_id"] == data["revision"]["id"]
    assert Repo.get!(Revision, original.id) == original
    assert Repo.get!(Progression, progression.id) == progression
    assert Repo.get!(AsyncWorlds.Ticks.Tick, tick.id) == frozen
    error(request(:post, "#{@copies}/#{work.id}/release", body), 409, "stale_working_copy")
    assert Repo.aggregate(Revision, :count) == 3
  end

  test "invalid release rolls back draft and library, while incomplete saves remain possible", %{
    campaign: campaign
  } do
    {:ok, work} = Quests.create_working_copy(campaign, "456")
    error(request(:post, "#{@copies}/#{work.id}/release", edit(work)), 422, "invalid_document")
    assert Repo.get!(WorkingCopy, work.id) == work
    assert Repo.aggregate(Revision, :count) == 2
    assert Repo.aggregate(Quest, :count) == 2

    error(
      request(
        :post,
        "#{@copies}/#{work.id}/release",
        edit(work)
        |> Map.put("name", "Bad")
        |> Map.put("definition", Map.put(work.definition, "start_node", "missing"))
      ),
      422,
      "invalid_document"
    )

    assert Repo.get!(WorkingCopy, work.id).version == 1
  end

  test "stale saves and import-changed bases fail without overwriting", %{
    campaign: campaign,
    work: work,
    revision: revision
  } do
    saved = json_response(request(:put, "#{@copies}/#{work.id}", edit(work)), 200)["data"]
    error(request(:put, "#{@copies}/#{work.id}", edit(work)), 409, "stale_working_copy")

    doc = %{
      "version" => 1,
      "quests" => [
        %{
          "name" => "Import rename",
          "content_id" => work.content_id,
          "definition" => revision.definition
        }
      ]
    }

    assert json_response(request(:post, @url <> "/import", doc), 200)

    for {method, suffix} <- [{:put, ""}, {:post, "/release"}] do
      error(
        request(
          method,
          "#{@copies}/#{work.id}#{suffix}",
          Map.put(attrs(work), "version", saved["version"])
        ),
        409,
        "stale_base_revision"
      )
    end

    assert Repo.get!(WorkingCopy, work.id).version == saved["version"]
    assert {:ok, library} = Quests.library(campaign, "456")
    assert length(library.revisions) == 2
  end

  test "recovery forks client-preserved work despite stale version or base and leaves original untouched",
       %{campaign: campaign, work: work} do
    {:ok, saved} =
      Quests.save_working_copy(campaign, "456", work.id, work.version, %{
        name: "Other tab",
        content_id: work.content_id,
        definition: work.definition
      })

    local =
      attrs(work)
      |> Map.put("name", "My unsaved narrative")
      |> Map.put("definition", put_in(work.definition, ["nodes", Access.at(0), "text"], "Local"))

    data = json_response(request(:post, "#{@copies}/#{work.id}/recover", local), 201)["data"]
    assert data["id"] != to_string(work.id)
    assert data["name"] == "My unsaved narrative (recovered)"
    assert data["quest_id"] == nil
    assert data["base_revision_id"] == nil
    assert data["version"] == 1
    assert data["content_id"] != work.content_id
    assert data["definition"] == local["definition"]
    assert Repo.get!(WorkingCopy, work.id) == saved
    body = Map.take(data, ~w(name content_id definition version))

    released =
      json_response(request(:post, "#{@copies}/#{data["id"]}/release", body), 200)["data"]

    assert released["revision"]["quest_id"] != to_string(work.quest_id)
  end

  test "stable identities, opaque content and persistence validation remain shared", %{
    campaign: campaign,
    work: work
  } do
    for definition <- [
          put_in(work.definition, ["nodes", Access.at(0), "id"], "forged"),
          Map.put(work.definition, "extra", true)
        ] do
      error(
        request(:put, "#{@copies}/#{work.id}", Map.put(edit(work), "definition", definition)),
        422,
        "unsupported_edit"
      )
    end

    error(
      request(
        :put,
        "#{@copies}/#{work.id}",
        Map.put(edit(work), "content_id", "changed_identity")
      ),
      422,
      "immutable_content_id"
    )

    for {method, suffix, body} <- [
          {:put, "", edit(work)},
          {:post, "/release", edit(work)},
          {:post, "/recover", attrs(work)}
        ] do
      error(
        request(method, "#{@copies}/#{work.id}#{suffix}", Map.put(body, "name", "bad\u0000name")),
        422,
        "invalid_document"
      )
    end

    assert Repo.get!(WorkingCopy, work.id) == work

    {:ok, rolled_revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Rolled", content_id: "rolled"},
        replace_choice(definition(), rolled())
      )

    data =
      json_response(
        request(:post, @copies, %{"revision_id" => to_string(rolled_revision.id)}),
        201
      )["data"]

    assert data["definition"] == rolled_revision.definition
    body = Map.take(data, ~w(name content_id definition version))

    released =
      json_response(request(:post, "#{@copies}/#{data["id"]}/release", body), 200)["data"]

    assert released["revision"]["definition"] == rolled_revision.definition
  end

  test "native clock references survive revision, working-copy and release roundtrips", %{
    campaign: campaign
  } do
    {:ok, clock} = Quests.create_clock(campaign, "456", %{name: "Alarm", segments: 4})

    definition =
      definition()
      |> put_in(["nodes", Access.at(0), "choices", Access.at(0), "conditions"], [
        %{"type" => "clock_threshold", "clock_id" => clock.id, "operator" => "gte", "value" => 2}
      ])
      |> put_in(
        ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "effects"],
        [%{"type" => "clock_delta", "clock_id" => clock.id, "delta" => 1}]
      )

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Clock quest", content_id: "clock_quest"},
        definition
      )

    assert json_response(request(:get, "#{@url}/revisions/#{revision.id}"), 200)["data"][
             "definition"
           ] == definition

    data =
      json_response(request(:post, @copies, %{"revision_id" => to_string(revision.id)}), 201)[
        "data"
      ]

    assert data["definition"] == definition
    body = Map.take(data, ~w(name content_id definition version))

    released =
      json_response(request(:post, "#{@copies}/#{data["id"]}/release", body), 200)["data"]

    assert released["revision"]["definition"] == definition
  end

  test "duplicate release identities leave drafts and revisions unchanged", %{
    campaign: campaign,
    work: existing
  } do
    {:ok, blank} = Quests.create_working_copy(campaign, "456")

    node = %{
      "id" => "node_" <> Ecto.UUID.generate(),
      "text" => "Ending",
      "ending" => true,
      "choices" => []
    }

    body =
      edit(blank)
      |> Map.put("name", "Duplicate")
      |> Map.put("content_id", existing.content_id)
      |> Map.put("definition", %{"start_node" => node["id"], "nodes" => [node]})

    error(request(:post, "#{@copies}/#{blank.id}/release", body), 422, "invalid_parameters")
    assert Repo.get!(WorkingCopy, blank.id) == blank
    assert Repo.aggregate(Revision, :count) == 2
  end

  test "requires JSON and renders malformed or oversized bodies safely" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("accept", "application/json")

    error(
      conn |> put_req_header("content-type", "text/plain") |> post(@copies, "{}"),
      415,
      "unsupported_media_type"
    )

    {400, _, body} =
      assert_error_sent 400, fn ->
        conn |> put_req_header("content-type", "application/json") |> post(@copies, "{")
      end

    assert Jason.decode!(body) == %{"error" => %{"code" => "invalid_json"}}

    {413, _, body} =
      assert_error_sent 413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@copies, String.duplicate(" ", 8_000_001))
      end

    assert Jason.decode!(body) == %{"error" => %{"code" => "payload_too_large"}}
  end

  test "foreign and malformed resources stay concealed on every scoped entry point", %{
    work: work,
    foreign_work: foreign_work,
    foreign_revision: foreign_revision
  } do
    for id <- [foreign_work.id, "bad", "9223372036854775808", "999999"] do
      error(request(:get, "#{@copies}/#{id}"), 404, "not_found")

      for {method, suffix, body} <- [
            {:put, "", edit(work)},
            {:post, "/release", edit(work)},
            {:post, "/recover", attrs(work)}
          ] do
        error(request(method, "#{@copies}/#{id}#{suffix}", body), 404, "not_found")
      end
    end

    for id <- [foreign_revision.id, "bad", "999999", nil] do
      error(request(:post, @copies, %{"revision_id" => id}), 404, "not_found")
    end

    error(request(:get, "#{@url}/revisions/#{foreign_revision.id}"), 404, "not_found")

    for guild <- ["999", "bad"] do
      error(request(:get, "/api/campaigns/#{guild}/quests"), 404, "not_found")
    end
  end

  test "authentication, revoked access and untrusted fields cannot change authoring scope", %{
    campaign: campaign,
    work: work
  } do
    assert build_conn() |> get(@url) |> json_response(401)

    for field <- ~w(dm_user_id campaign_id source_definition quest_id base_revision_id id) do
      error(request(:post, @copies, %{field => "999"}), 422, "invalid_parameters")

      error(
        request(:put, "#{@copies}/#{work.id}", Map.put(edit(work), field, "999")),
        422,
        "invalid_parameters"
      )
    end

    error(request(:get, @url <> "?dm_user_id=999"), 422, "invalid_parameters")
    error(request(:post, @copies, []), 422, "invalid_parameters")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: campaign.discord_guild_id,
        dm_user_id: "457",
        public_channel_id: "789"
      })

    for {method, path, body} <- [
          {:get, @url, %{}},
          {:post, @copies, %{}},
          {:get, "#{@copies}/#{work.id}", %{}},
          {:put, "#{@copies}/#{work.id}", edit(work)},
          {:post, "#{@copies}/#{work.id}/release", edit(work)},
          {:post, "#{@copies}/#{work.id}/recover", attrs(work)}
        ] do
      error(request(method, path, body), 404, "not_found")
    end

    assert Repo.get!(WorkingCopy, work.id) == work
  end
end
