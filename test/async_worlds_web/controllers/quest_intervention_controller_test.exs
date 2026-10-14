defmodule AsyncWorldsWeb.QuestInterventionControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.QuestFixtures

  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.{Intervention, Progression, Submissions, Unlock}

  @token String.duplicate("i", 32)
  @base "/api/campaigns/123"

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

    {:ok, a} = Characters.create_character(campaign, "456", %{name: "A", discord_user_id: "991"})
    {:ok, b} = Characters.create_character(campaign, "456", %{name: "B", discord_user_id: "992"})
    {:ok, foreign} = Characters.create_character(other, "456", %{name: "Foreign"})

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{name: "Quest", content_id: "quest"}, definition())

    {:ok, foreign_revision} =
      Quests.create_quest(other, "456", %{name: "Foreign", content_id: "foreign"}, definition())

    %{
      campaign: campaign,
      a: a,
      b: b,
      foreign: foreign,
      revision: revision,
      foreign_revision: foreign_revision
    }
  end

  defp quest_path(id), do: "#{@base}/characters/#{id}/quests"

  defp request(method, path, body \\ %{}) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    if method == :get, do: get(conn, path), else: post(conn, path, Jason.encode!(body))
  end

  defp error(conn, status, code), do: assert(json_response(conn, status)["error"]["code"] == code)
  defp selected(id), do: json_response(request(:get, quest_path(id)), 200)["data"]["selected"]

  defp body(expected, extras \\ %{}),
    do: Map.merge(%{"expected_progression" => expected, "reason" => "DM intervention"}, extras)

  defp assign_character(character, revision) do
    json_response(
      request(
        :post,
        quest_path(character.id) <> "/assign",
        body(nil, %{"revision_id" => to_string(revision.id)})
      ),
      200
    )["data"]
  end

  defp submit(user, choice \\ "loop") do
    {:ok, state} = Submissions.player_state("123", user)
    {:ok, _} = Submissions.submit("123", user, state.identity, choice)
  end

  test "management reads expose explicit DM state without leaking schemas", c do
    conn = request(:get, @base <> "/quests/management")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => data} = json_response(conn, 200)
    assert Enum.map(data["characters"], & &1["id"]) == [to_string(c.a.id), to_string(c.b.id)]
    assert data["selected"] == nil
    assert data["interventions"] == []
    refute data["locked"]

    assert data["revisions"] == [
             %{
               "id" => to_string(c.revision.id),
               "quest_name" => "Quest",
               "content_id" => "quest",
               "number" => 1
             }
           ]

    assert selected(c.a.id)["progression"] == nil
    assert selected(c.a.id)["revision"] == nil
    progression = assign_character(c.a, c.revision)
    assert selected(c.a.id)["progression"] == progression
    assert selected(c.a.id)["revision"]["definition"] == c.revision.definition

    assert Enum.sort(Map.keys(progression)) ==
             Enum.sort(
               ~w(id campaign_id character_id revision_id node_id position_version status)
             )
  end

  test "assignment is independently audited with required reasons and verified actor", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    params =
      body(nil, %{"revision_id" => to_string(c.revision.id), "reason" => "  Introduce story  "})

    data = json_response(request(:post, quest_path(c.a.id) <> "/assign", params), 200)["data"]
    assert data["status"] == "active"
    assert data["node_id"] == "hub"
    assert data["position_version"] == 1
    assert data["character_id"] == to_string(c.a.id)
    assert selected(c.b.id)["progression"] == nil
    audit = hd(json_response(request(:get, quest_path(c.a.id) <> "/interventions"), 200)["data"])
    assert audit["actor_id"] == "456"
    assert audit["reason"] == "Introduce story"
    assert audit["operation"] == "assign"
    assert audit["tick_id"] == to_string(tick.id)
    assert audit["before"] == nil
    assert audit["after"]["id"] == data["id"]
    assert audit["after"]["revision_id"] == to_string(c.revision.id)
    assert audit["invalidated_submissions"] == 0

    assert Map.keys(audit["after"]) |> Enum.sort() ==
             Enum.sort(~w(id character_id revision_id node_id position_version status))

    error(
      request(
        :post,
        quest_path(c.a.id) <> "/assign",
        body(data, %{"revision_id" => to_string(c.revision.id)})
      ),
      409,
      "active_quest"
    )
  end

  test "absence is explicit and active assignment identity cannot be inferred or forged", c do
    path = quest_path(c.a.id) <> "/assign"

    error(
      request(:post, path, %{"reason" => "Reason", "revision_id" => to_string(c.revision.id)}),
      428,
      "precondition_required"
    )

    assigned = assign_character(c.a, c.revision)

    error(
      request(:post, path, body(nil, %{"revision_id" => to_string(c.revision.id)})),
      409,
      "stale_progression"
    )

    for invalid <- [
          false,
          "latest",
          %{},
          Map.put(assigned, "position_version", 1.0),
          Map.put(assigned, "actor_id", "999")
        ] do
      error(
        request(:post, quest_path(c.a.id) <> "/end", body(invalid)),
        if(invalid == %{}, do: 428, else: 422),
        if(invalid == %{}, do: "precondition_required", else: "invalid_parameters")
      )
    end

    error(
      request(
        :post,
        quest_path(c.a.id) <> "/end",
        body(Map.delete(assigned, "position_version"))
      ),
      428,
      "precondition_required"
    )

    for {field, value} <- [
          {"id", "999999"},
          {"campaign_id", to_string(c.foreign.campaign_id)},
          {"character_id", to_string(c.b.id)},
          {"revision_id", to_string(c.foreign_revision.id)},
          {"node_id", "end"},
          {"status", "ended"},
          {"position_version", 2}
        ] do
      error(
        request(:post, quest_path(c.a.id) <> "/end", body(Map.put(assigned, field, value))),
        409,
        "stale_progression"
      )
    end

    assert selected(c.a.id)["progression"] == assigned
    assert Repo.aggregate(Intervention, :count) == 1
  end

  test "all mutations reject missing, blank, NUL or oversized reasons without side effects", c do
    for reason <- [nil, " ", "bad\u0000reason", String.duplicate("x", 2001), %{}] do
      error(
        request(
          :post,
          quest_path(c.a.id) <> "/assign",
          body(nil, %{"revision_id" => to_string(c.revision.id), "reason" => reason})
        ),
        422,
        "invalid_reason"
      )
    end

    assigned = assign_character(c.a, c.revision)

    for {operation, extras} <- [
          {"replace", %{"revision_id" => to_string(c.revision.id)}},
          {"move", %{"node_id" => "end"}},
          {"end", %{}}
        ],
        reason <- [nil, " ", "bad\u0000reason", String.duplicate("x", 2001)] do
      error(
        request(
          :post,
          quest_path(c.a.id) <> "/" <> operation,
          body(assigned, Map.put(extras, "reason", reason))
        ),
        422,
        "invalid_reason"
      )
    end

    error(
      request(:post, quest_path(c.a.id) <> "/end", %{"expected_progression" => assigned}),
      422,
      "invalid_reason"
    )

    assert Repo.aggregate(Intervention, :count) == 1
    assert selected(c.a.id)["progression"] == assigned
  end

  test "move no-op preserves choices; actual move completes and invalidates only this character",
       c do
    a = assign_character(c.a, c.revision)
    b = assign_character(c.b, c.revision)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    submit("991")
    submit("992")

    data =
      json_response(
        request(:post, quest_path(c.a.id) <> "/move", body(a, %{"node_id" => "hub"})),
        200
      )["data"]

    assert data == a
    assert Repo.aggregate(Intervention, :count) == 2
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")

    moved =
      json_response(
        request(:post, quest_path(c.a.id) <> "/move", body(a, %{"node_id" => "end"})),
        200
      )["data"]

    assert moved["status"] == "completed"
    assert moved["position_version"] == a["position_version"] + 1
    assert selected(c.a.id)["progression"] == nil
    assert selected(c.b.id)["progression"] == b
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "992")
    audit = hd(json_response(request(:get, quest_path(c.a.id) <> "/interventions"), 200)["data"])
    assert audit["operation"] == "move"
    assert audit["before"]["node_id"] == "hub"
    assert audit["after"]["status"] == "completed"
    assert audit["invalidated_submissions"] == 1
    assert audit["tick_id"] == to_string(tick.id)
  end

  test "replacement restarts the same revision with a new identity and invalidates choices", c do
    assigned = assign_character(c.a, c.revision)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    submit("991")

    replaced =
      json_response(
        request(
          :post,
          quest_path(c.a.id) <> "/replace",
          body(assigned, %{"revision_id" => to_string(c.revision.id)})
        ),
        200
      )["data"]

    assert replaced["id"] != assigned["id"]
    assert replaced["position_version"] == assigned["position_version"]
    assert replaced["revision_id"] == assigned["revision_id"]
    assert Repo.get!(Progression, assigned["id"]).status == :ended
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "991")
    audit = hd(json_response(request(:get, quest_path(c.a.id) <> "/interventions"), 200)["data"])
    assert audit["before"]["id"] == assigned["id"]
    assert audit["after"]["id"] == replaced["id"]
    assert audit["invalidated_submissions"] == 1
    error(request(:post, quest_path(c.a.id) <> "/end", body(assigned)), 409, "stale_progression")
  end

  test "ending preserves history and clears submissions; operations without a quest fail", c do
    assigned = assign_character(c.a, c.revision)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    submit("991")

    ended =
      json_response(request(:post, quest_path(c.a.id) <> "/end", body(assigned)), 200)["data"]

    assert ended["status"] == "ended"
    assert ended["id"] == assigned["id"]
    assert selected(c.a.id)["progression"] == nil
    audit = hd(json_response(request(:get, quest_path(c.a.id) <> "/interventions"), 200)["data"])
    assert audit["invalidated_submissions"] == 1
    assert audit["operation"] == "end"
    error(request(:post, quest_path(c.a.id) <> "/end", body(assigned)), 409, "stale_progression")
    error(request(:post, quest_path(c.a.id) <> "/end", body(nil)), 404, "no_quest")

    error(
      request(:post, quest_path(c.a.id) <> "/move", body(nil, %{"node_id" => "hub"})),
      404,
      "no_quest"
    )
  end

  test "every write requires a precondition and ABA movement cannot reuse an old position", c do
    middle = %{
      "id" => "middle",
      "text" => "Middle",
      "ending" => false,
      "choices" => [choice("return", "hub")]
    }

    definition = Map.update!(definition(), "nodes", &(&1 ++ [middle]))

    {:ok, revision} =
      Quests.create_quest(c.campaign, "456", %{name: "ABA", content_id: "aba"}, definition)

    assigned = assign_character(c.a, revision)

    for {op, extra} <- [
          {"assign", %{"revision_id" => to_string(revision.id)}},
          {"replace", %{"revision_id" => to_string(revision.id)}},
          {"move", %{"node_id" => "middle"}},
          {"end", %{}}
        ] do
      error(
        request(:post, quest_path(c.a.id) <> "/" <> op, Map.put(extra, "reason", "Reason")),
        428,
        "precondition_required"
      )
    end

    moved =
      json_response(
        request(:post, quest_path(c.a.id) <> "/move", body(assigned, %{"node_id" => "middle"})),
        200
      )["data"]

    returned =
      json_response(
        request(:post, quest_path(c.a.id) <> "/move", body(moved, %{"node_id" => "hub"})),
        200
      )["data"]

    assert returned["node_id"] == assigned["node_id"]
    assert returned["id"] == assigned["id"]
    assert returned["position_version"] > assigned["position_version"]

    for {op, extra} <- [
          {"assign", %{"revision_id" => to_string(revision.id)}},
          {"replace", %{"revision_id" => to_string(revision.id)}},
          {"move", %{"node_id" => "middle"}},
          {"end", %{}}
        ] do
      error(
        request(:post, quest_path(c.a.id) <> "/" <> op, body(assigned, extra)),
        409,
        "stale_progression"
      )
    end

    assert Repo.aggregate(Intervention, :count) == 3
  end

  test "assigning an ending start node completes immediately and replacement from absence is explicit",
       c do
    definition = %{
      "start_node" => "ending",
      "nodes" => [%{"id" => "ending", "text" => "Done", "ending" => true, "choices" => []}]
    }

    {:ok, revision} =
      Quests.create_quest(c.campaign, "456", %{name: "Ending", content_id: "ending"}, definition)

    completed = assign_character(c.a, revision)
    assert completed["status"] == "completed"
    assert selected(c.a.id)["progression"] == nil

    replaced =
      json_response(
        request(
          :post,
          quest_path(c.a.id) <> "/replace",
          body(nil, %{"revision_id" => to_string(c.revision.id)})
        ),
        200
      )["data"]

    assert replaced["status"] == "active"
    assert replaced["id"] != completed["id"]

    assert hd(json_response(request(:get, quest_path(c.a.id) <> "/interventions"), 200)["data"])[
             "before"
           ] == nil
  end

  test "bad target revisions or nodes roll back invalidation and audit writes", c do
    assigned = assign_character(c.a, c.revision)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    submit("991")

    for revision <- [c.foreign_revision.id, "999999", "bad", "9223372036854775808"] do
      error(
        request(
          :post,
          quest_path(c.a.id) <> "/replace",
          body(assigned, %{"revision_id" => to_string(revision)})
        ),
        404,
        "not_found"
      )
    end

    for node <- ["unknown", nil, %{}] do
      error(
        request(:post, quest_path(c.a.id) <> "/move", body(assigned, %{"node_id" => node})),
        422,
        "invalid_node"
      )
    end

    assert selected(c.a.id)["progression"] == assigned
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")
    assert Repo.aggregate(Intervention, :count) == 1
  end

  test "unlocked availability is character scoped and does not assign automatically", c do
    Repo.insert!(%Unlock{
      campaign_id: c.campaign.id,
      character_id: c.a.id,
      quest_id: c.revision.quest_id
    })

    Repo.insert!(%Unlock{
      campaign_id: c.foreign.campaign_id,
      character_id: c.foreign.id,
      quest_id: c.foreign_revision.quest_id
    })

    assert json_response(request(:get, quest_path(c.a.id) <> "/unlocked"), 200)["data"] == [
             %{
               "id" => to_string(c.revision.quest_id),
               "campaign_id" => to_string(c.campaign.id),
               "name" => "Quest",
               "content_id" => "quest"
             }
           ]

    assert json_response(request(:get, quest_path(c.b.id) <> "/unlocked"), 200)["data"] == []
    assert selected(c.a.id)["progression"] == nil
  end

  test "tick locks block all interventions and preserve frozen input, but reads remain available",
       c do
    assigned = assign_character(c.a, c.revision)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    submit("991")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

    for stage <- [:resolving, :in_review] do
      if stage == :in_review do
        {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
        {:ok, _} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
      end

      error(
        request(
          :post,
          quest_path(c.b.id) <> "/assign",
          body(nil, %{"revision_id" => to_string(c.revision.id)})
        ),
        409,
        "tick_locked"
      )

      for {operation, extras} <- [
            {"replace", %{"revision_id" => to_string(c.revision.id)}},
            {"move", %{"node_id" => "end"}},
            {"end", %{}}
          ] do
        error(
          request(:post, quest_path(c.a.id) <> "/" <> operation, body(assigned, extras)),
          409,
          "tick_locked"
        )
      end

      assert json_response(request(:get, quest_path(c.a.id)), 200)["data"]["locked"]
      assert json_response(request(:get, quest_path(c.a.id) <> "/unlocked"), 200)
      assert json_response(request(:get, quest_path(c.a.id) <> "/interventions"), 200)
      assert Repo.aggregate(Intervention, :count) == 1
      assert {:ok, ^snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)
    end
  end

  test "JSON request validation rejects wrong media type, malformed bodies and non-object input",
       c do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("accept", "application/json")

    error(
      conn
      |> put_req_header("content-type", "text/plain")
      |> post(quest_path(c.a.id) <> "/assign", "{}"),
      415,
      "unsupported_media_type"
    )

    {400, _, body} =
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(quest_path(c.a.id) <> "/assign", "{")
      end

    assert Jason.decode!(body) == %{"error" => %{"code" => "invalid_json"}}
    error(request(:post, quest_path(c.a.id) <> "/assign", []), 422, "invalid_parameters")
    assert Repo.aggregate(Intervention, :count) == 0
  end

  test "all resources are campaign scoped, identities cannot authorize and revoked access fails",
       c do
    for id <- [c.foreign.id, "999999", "bad", "9223372036854775808"] do
      for suffix <- ["", "/unlocked", "/interventions"] do
        error(request(:get, quest_path(id) <> suffix), 404, "not_found")
      end

      for {op, extra} <- [
            {"assign", %{"revision_id" => to_string(c.revision.id)}},
            {"replace", %{"revision_id" => to_string(c.revision.id)}},
            {"move", %{"node_id" => "hub"}},
            {"end", %{}}
          ] do
        error(request(:post, quest_path(id) <> "/" <> op, body(nil, extra)), 404, "not_found")
      end
    end

    for key <-
          ~w(actor_id dm_user_id campaign_id character_id source progression_id position_version) do
      error(
        request(
          :post,
          quest_path(c.a.id) <> "/assign",
          body(nil, %{"revision_id" => to_string(c.revision.id), key => "999"})
        ),
        422,
        "invalid_parameters"
      )
    end

    error(request(:get, quest_path(c.a.id) <> "?dm_user_id=999"), 422, "invalid_parameters")
    assert build_conn() |> get(@base <> "/quests/management") |> json_response(401)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    error(request(:get, @base <> "/quests/management"), 404, "not_found")

    error(
      request(
        :post,
        quest_path(c.a.id) <> "/assign",
        body(nil, %{"revision_id" => to_string(c.revision.id)})
      ),
      404,
      "not_found"
    )

    assert Repo.aggregate(Intervention, :count) == 0
  end
end
