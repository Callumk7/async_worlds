defmodule AsyncWorldsWeb.TickReviewControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.QuestFixtures

  alias AsyncWorlds.{Campaigns, Characters, Clocks, Deliveries, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Ticks.{Draft, Publication, ReviewEdit, Roll, WorldResolver}

  @token String.duplicate("r", 32)

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

    {:ok, clock} =
      Clocks.create_clock(
        campaign.id,
        %{name: "Hidden mechanism", visibility: :hidden, segments: 4, background_rate: 1},
        "dm"
      )

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{content_id: "quest", name: "Quest"},
        replace_choice(definition(), rolled())
      )

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, state} = Submissions.player_state("123", "991")
    {:ok, _} = Submissions.submit("123", "991", state.identity, "roll")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, rolls} = Ticks.record_quest_rolls(campaign.id, tick.id, snapshot.revision, fn -> 1 end)
    {:ok, payload} = WorldResolver.resolve(snapshot, %{}, rolls)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    %{
      campaign: campaign,
      tick: tick,
      snapshot: snapshot,
      draft: draft,
      clock: clock,
      url: "/api/campaigns/123/ticks/#{tick.id}"
    }
  end

  defp request(method, path, body \\ %{}) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body))
    end
  end

  defp error(conn, status, code),
    do: assert(json_response(conn, status) == %{"error" => %{"code" => code}})

  defp review(c), do: json_response(request(:get, c.url <> "/review"), 200)["data"]

  defp edit(c, draft_id, operation, reason \\ "Reviewed correction") do
    request(:post, c.url <> "/review/edits", %{
      draft_id: draft_id,
      reason: reason,
      operation: operation
    })
  end

  defp preview(c, draft_id),
    do:
      json_response(request(:get, c.url <> "/review/preview?draft_id=#{draft_id}"), 200)["data"][
        "outputs"
      ]

  test "review is projected and exact preview uses the selected current revision", c do
    conn = request(:get, c.url <> "/review")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    data = json_response(conn, 200)["data"]
    assert data["id"] == c.draft.id
    assert data["tick_id"] == to_string(c.tick.id)
    assert data["input_revision"] == c.snapshot.revision

    assert Map.keys(data) |> Enum.sort() ==
             Enum.sort(
               ~w(id tick_id input_revision revision inserted_at world_news world_news_override clocks quests)
             )

    assert hd(data["clocks"])["id"] == to_string(c.clock.id)
    quest = hd(data["quests"])
    assert is_binary(quest["input"]["revision_id"])
    assert is_integer(quest["input"]["position_version"])
    assert length(quest["dice"]) == 3

    {:ok, outputs} =
      AsyncWorlds.DM.Ticks.preview_draft(
        %{campaign: c.campaign, discord_user_id: "456"},
        c.tick.id,
        c.draft.id
      )

    expected =
      Map.new(~w(public dm players), fn key ->
        {key, Enum.map(outputs[key] || [], &Map.take(&1, ~w(kind recipient_id content)))}
      end)

    assert preview(c, c.draft.id) == expected
    refute Enum.any?(expected["public"], &String.contains?(&1["content"], "Hidden mechanism"))
    assert Enum.any?(expected["dm"], &String.contains?(&1["content"], "Hidden mechanism"))
  end

  test "world edits audit reasons, replace deltas and clear narration without blind retries", c do
    data =
      json_response(
        edit(c, c.draft.id, %{type: "clock_delta", clock_id: to_string(c.clock.id), delta: 3}),
        200
      )["data"]

    id = data["draft"]["id"]
    assert id != c.draft.id

    error(
      request(:post, c.url <> "/publish", %{draft_id: c.draft.id, confirm: true}),
      409,
      "stale_draft"
    )

    assert Repo.all(Publication) == []
    assert data["audit"]["actor_id"] == "456"
    assert data["audit"]["reason"] == "Reviewed correction"
    assert data["audit"]["operation"]["clock_id"] == to_string(c.clock.id)
    assert hd(review(c)["clocks"])["filled"] == 3
    error(edit(c, c.draft.id, %{type: "world_news", text: ["News"]}), 409, "stale_draft")
    error(request(:get, c.url <> "/review/preview?draft_id=#{c.draft.id}"), 409, "stale_draft")

    news =
      json_response(edit(c, id, %{type: "world_news", text: ["Approved news"]}), 200)["data"][
        "draft"
      ]["id"]

    assert Enum.any?(
             preview(c, news)["public"],
             &String.contains?(&1["content"], "Approved news")
           )

    cleared =
      json_response(edit(c, news, %{type: "world_news", text: nil}), 200)["data"]["draft"]["id"]

    assert review(c)["world_news_override"] == nil

    json_response(
      edit(c, cleared, %{type: "clock_delta", clock_id: to_string(c.clock.id), delta: nil}),
      200
    )

    assert hd(review(c)["clocks"])["filled"] == 1
    assert Repo.aggregate(ReviewEdit, :count) == 4
  end

  test "quest edits roundtrip projected identities and rerolls preserve original/unrelated dice",
       c do
    quest = hd(review(c)["quests"])
    original = Repo.all(Roll)

    operation = %{
      type: "outcome",
      input_revision: c.snapshot.revision,
      input: quest["input"],
      value: "success"
    }

    error(
      edit(c, c.draft.id, Map.put(operation, :input_revision, Ecto.UUID.generate())),
      409,
      "stale_input"
    )

    changed_input = Map.put(quest["input"], "position_version", 999)
    error(edit(c, c.draft.id, Map.put(operation, :input, changed_input)), 409, "stale_identity")
    id = json_response(edit(c, c.draft.id, operation), 200)["data"]["draft"]["id"]
    assert hd(review(c)["quests"])["outcome"] == "success"
    assert hd(review(c)["quests"])["after"]["status"] == "completed"

    narration = %{
      type: "player_narration",
      input_revision: c.snapshot.revision,
      input: quest["input"],
      value: "Approved result"
    }

    id = json_response(edit(c, id, narration), 200)["data"]["draft"]["id"]

    assert Enum.any?(
             preview(c, id)["players"],
             &String.contains?(&1["content"], "Approved result")
           )

    die = hd(quest["dice"])
    reroll = %{type: "reroll", identity: die["identity"], old_value: die["value"]}
    data = json_response(edit(c, id, reroll), 200)["data"]
    audit = data["audit"]["operation"]
    assert audit["new_value"] in 1..6
    assert audit["old_value"] == 1
    assert audit["identity"] == die["identity"]
    dice = hd(review(c)["quests"])["dice"]
    assert hd(dice)["value"] == audit["new_value"]
    assert tl(dice) == tl(quest["dice"])
    assert Repo.all(Roll) == original
    id = data["draft"]["id"]
    id = json_response(edit(c, id, Map.put(narration, :value, nil)), 200)["data"]["draft"]["id"]
    json_response(edit(c, id, Map.put(operation, :value, nil)), 200)
    assert hd(review(c)["quests"])["outcome_override"] == nil
    assert hd(review(c)["quests"])["narration_override"] == nil
  end

  test "publication requires explicit approval and atomically retains exact output", c do
    outputs = preview(c, c.draft.id)
    before = Deliveries.list_deliveries(c.campaign.id)
    path = c.url <> "/publish"
    error(request(:post, path, %{draft_id: c.draft.id}), 409, "confirmation_required")

    error(
      request(:post, path, %{draft_id: c.draft.id, confirm: "true"}),
      422,
      "invalid_parameters"
    )

    error(request(:post, path, %{confirm: true}), 428, "precondition_required")
    assert Repo.all(Publication) == []
    assert Deliveries.list_deliveries(c.campaign.id) == before

    data =
      json_response(request(:post, path, %{draft_id: c.draft.id, confirm: true}), 200)["data"]

    assert data["status"] == "published"
    assert data["tick_id"] == to_string(c.tick.id)
    {:ok, publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)

    assert Map.new(outputs, fn {key, _messages} ->
             {key,
              Enum.map(
                publication.outputs[key] || [],
                &Map.take(&1, ~w(kind recipient_id content))
              )}
           end) == outputs

    assert Repo.get!(AsyncWorlds.Campaigns.Campaign, c.campaign.id).current_tick_number == 1
    refute Repo.get!(AsyncWorlds.Campaigns.Campaign, c.campaign.id).clock_mutations_locked
    deliveries = Deliveries.list_deliveries(c.campaign.id)
    assert length(deliveries) > length(before)
    error(request(:post, path, %{draft_id: c.draft.id, confirm: true}), 409, "already_published")
    assert Deliveries.list_deliveries(c.campaign.id) == deliveries
  end

  test "missing/stale tokens, malformed operations and invalid reasons do not append revisions",
       c do
    error(request(:get, c.url <> "/review/preview"), 428, "precondition_required")
    error(request(:get, c.url <> "/review/preview?draft_id=bad"), 422, "invalid_parameters")
    error(edit(c, nil, %{type: "world_news", text: []}), 428, "precondition_required")

    for op <- [
          %{type: "reroll", identity: "bad", old_value: 1},
          %{type: "outcome", input_revision: c.snapshot.revision, input: %{}, value: "success"},
          %{type: "world_news", text: [""]},
          %{type: "clock_delta", clock_id: "999999", delta: 1},
          %{type: "reroll", identity: "bad", old_value: 1, new_value: 6}
        ] do
      conn = edit(c, c.draft.id, op)
      assert conn.status in [409, 422]
    end

    error(edit(c, c.draft.id, %{type: "world_news", text: []}, " "), 422, "invalid_reason")

    error(
      request(:post, c.url <> "/review/edits", %{draft_id: c.draft.id, actor_id: "456"}),
      422,
      "invalid_parameters"
    )

    assert Repo.all(ReviewEdit) == []
    assert Repo.aggregate(Draft, :count) == 1
  end

  test "fresh ownership and canonical validation conceal or reject unsafe access", c do
    error(get(build_conn(), c.url <> "/review"), 401, "unauthenticated")
    foreign_url = String.replace(c.url, "/123/", "/124/")
    error(request(:get, foreign_url <> "/review"), 404, "not_found")

    error(
      request(:post, foreign_url <> "/publish", %{draft_id: c.draft.id, confirm: true}),
      404,
      "not_found"
    )

    # A malformed stored draft cannot be exposed as a valid review or preview.
    {:ok, _} =
      Repo.insert(%Draft{
        tick_id: c.tick.id,
        input_revision: c.snapshot.revision,
        revision: 2,
        payload: %{}
      })

    Repo.get!(AsyncWorlds.Ticks.Tick, c.tick.id)
    |> Ecto.Changeset.change(draft_revision: 2)
    |> Repo.update!()

    error(request(:get, c.url <> "/review"), 500, "internal_error")
    c.campaign |> Ecto.Changeset.change(dm_user_id: "457") |> Repo.update!()
    error(request(:get, c.url <> "/review"), 404, "not_found")
    error(edit(c, c.draft.id, %{type: "world_news", text: []}), 404, "not_found")
  end

  test "live drift rejects publication without partial state or delivery writes", c do
    before = Deliveries.list_deliveries(c.campaign.id)
    c.clock |> Ecto.Changeset.change(filled: 2) |> Repo.update!()

    error(
      request(:post, c.url <> "/publish", %{draft_id: c.draft.id, confirm: true}),
      409,
      "stale_live_state"
    )

    assert Repo.all(Publication) == []
    assert Deliveries.list_deliveries(c.campaign.id) == before
    assert Repo.get!(AsyncWorlds.Ticks.Tick, c.tick.id).status == :in_review
    assert Repo.get!(AsyncWorlds.Campaigns.Campaign, c.campaign.id).clock_mutations_locked
  end
end
