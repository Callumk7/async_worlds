defmodule AsyncWorldsWeb.ClockControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false

  alias AsyncWorlds.{Campaigns, Characters, Repo}
  alias AsyncWorlds.DM.Clocks
  alias AsyncWorlds.Clocks.Audit
  alias AsyncWorldsWeb.ApiTokens

  @token String.duplicate("k", 32)
  @url "/api/campaigns/123/clocks"

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

    scope = %{campaign: campaign, discord_user_id: "456"}
    other_scope = %{campaign: other, discord_user_id: "456"}
    {:ok, clock} = Clocks.create_clock(scope, %{name: "Secret", segments: 4, visibility: :hidden})
    {:ok, partner} = Clocks.create_clock(scope, %{name: "Partner", segments: 6})
    {:ok, foreign} = Clocks.create_clock(other_scope, %{name: "Foreign", segments: 4})
    %{scope: scope, other: other_scope, clock: clock, partner: partner, foreign: foreign}
  end

  defp request(method, path, body \\ %{}) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    body = Jason.encode!(body)

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, body)
      :patch -> patch(conn, path, body)
    end
  end

  defp error(conn, status, code), do: assert(json_response(conn, status)["error"]["code"] == code)
  defp snapshot(scope, clock), do: %{"snapshot_token" => ApiTokens.clock_snapshot(scope, clock)}

  defp current(scope, id) do
    {:ok, clock} = Clocks.get_clock(scope, id)
    clock
  end

  test "DM reads include hidden state and explicit scoped snapshots", %{
    scope: scope,
    clock: clock
  } do
    conn = request(:get, @url)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => [first, _]} = json_response(conn, 200)
    assert first["id"] == to_string(clock.id)
    assert first["campaign_id"] == to_string(clock.campaign_id)
    assert first["visibility"] == "hidden"
    assert first["filled"] == 0
    assert {:ok, ^clock} = ApiTokens.verify_clock_snapshot(scope, clock, first["snapshot_token"])

    assert Map.keys(first) |> Enum.sort() ==
             Enum.sort(
               ~w(id campaign_id name segments filled visibility background_rate paused completed racing_group triggers inserted_at updated_at snapshot_token)
             )

    assert json_response(request(:get, "#{@url}/#{clock.id}"), 200)["data"]["id"] == first["id"]
  end

  test "creation and editing clamp fill and preserve ordered triggers", %{
    scope: scope,
    clock: target
  } do
    triggers = [
      %{"type" => "notify_dm", "text" => "Private"},
      %{"type" => "start_clock", "clock_id" => to_string(target.id)},
      %{"type" => "world_news", "text" => "News"}
    ]

    data =
      json_response(
        request(:post, @url, %{
          "name" => "New",
          "segments" => 6,
          "filled" => 99,
          "background_rate" => -1,
          "triggers" => triggers
        }),
        201
      )["data"]

    assert data["filled"] == 6
    assert data["triggers"] == triggers
    attrs = %{"snapshot_token" => data["snapshot_token"], "segments" => 4, "name" => "Edited"}
    updated = json_response(request(:patch, "#{@url}/#{data["id"]}", attrs), 200)["data"]
    assert updated["filled"] == 4
    assert updated["triggers"] == triggers
    assert updated["background_rate"] == -1
    assert {:ok, audits} = Clocks.list_audits(scope)
    assert List.last(audits).operation == "edit"
    assert List.last(audits).source == "dm:http:456"
  end

  test "adjustment, pause, resume and reset retain domain behavior and audit tick attribution", %{
    scope: scope,
    clock: clock
  } do
    {:ok, tick} = AsyncWorlds.DM.Ticks.open_tick(scope)
    path = "#{@url}/#{clock.id}"

    data =
      json_response(
        request(:post, path <> "/adjust", Map.put(snapshot(scope, clock), "delta", 99)),
        200
      )["data"]

    assert data["filled"] == 4
    refute data["completed"]

    paused =
      json_response(
        request(:post, path <> "/pause", %{"snapshot_token" => data["snapshot_token"]}),
        200
      )["data"]

    assert paused["paused"]

    resumed =
      json_response(
        request(:post, path <> "/resume", %{"snapshot_token" => paused["snapshot_token"]}),
        200
      )["data"]

    refute resumed["paused"]

    reset =
      json_response(
        request(:post, path <> "/reset", %{"snapshot_token" => resumed["snapshot_token"]}),
        200
      )["data"]

    assert reset["filled"] == 0

    audits =
      Repo.all(Audit) |> Enum.filter(&(&1.clock_id == clock.id and &1.operation != "create"))

    assert Enum.map(audits, & &1.operation) == ["adjust", "edit", "edit", "reset"]
    assert Enum.all?(audits, &(&1.source == "dm:http:456" and &1.tick_id == tick.id))
  end

  test "racing writes require both snapshots, reset both and unpair both", %{
    scope: scope,
    clock: clock,
    partner: partner
  } do
    path = "#{@url}/#{clock.id}"
    params = snapshot(scope, clock) |> Map.put("partner_id", to_string(partner.id))
    error(request(:post, path <> "/pair", params), 428, "precondition_required")

    paired =
      json_response(
        request(
          :post,
          path <> "/pair",
          Map.put(params, "partner_snapshot_token", ApiTokens.clock_snapshot(scope, partner))
        ),
        200
      )["data"]

    assert length(paired) == 2
    assert hd(paired)["racing_group"] == List.last(paired)["racing_group"]
    {:ok, _} = Clocks.adjust_clock(scope, clock.id, 2)
    {:ok, _} = Clocks.adjust_clock(scope, partner.id, 3)
    clock = current(scope, clock.id)
    partner = current(scope, partner.id)
    error(request(:post, path <> "/reset", snapshot(scope, clock)), 428, "precondition_required")

    both =
      snapshot(scope, clock)
      |> Map.put("partner_snapshot_token", ApiTokens.clock_snapshot(scope, partner))

    assert json_response(request(:post, path <> "/reset", both), 200)["data"]["filled"] == 0
    assert current(scope, partner.id).filled == 0
    clock = current(scope, clock.id)
    partner = current(scope, partner.id)

    both =
      snapshot(scope, clock)
      |> Map.put("partner_snapshot_token", ApiTokens.clock_snapshot(scope, partner))

    unpaired = json_response(request(:post, path <> "/unpair", both), 200)["data"]
    assert length(unpaired) == 2
    assert Enum.all?(unpaired, &is_nil(&1["racing_group"]))
  end

  test "all mutations reject missing or stale tokens without writes or audits", %{
    scope: scope,
    clock: clock,
    partner: partner
  } do
    path = "#{@url}/#{clock.id}"
    {:ok, _} = Clocks.edit_clock(scope, clock.id, %{name: "Changed"})
    count = Repo.aggregate(Audit, :count)

    for {method, suffix, params} <- [
          {:patch, "", %{"name" => "No"}},
          {:post, "/adjust", %{"delta" => 1}},
          {:post, "/pause", %{}},
          {:post, "/resume", %{}},
          {:post, "/reset", %{}},
          {:post, "/unpair", %{}},
          {:post, "/pair",
           %{
             "partner_id" => to_string(partner.id),
             "partner_snapshot_token" => ApiTokens.clock_snapshot(scope, partner)
           }}
        ] do
      error(request(method, path <> suffix, params), 428, "precondition_required")

      error(
        request(method, path <> suffix, Map.merge(params, snapshot(scope, clock))),
        409,
        "stale_clock"
      )

      error(
        request(method, path <> suffix, Map.put(params, "snapshot_token", "tampered")),
        409,
        "stale_clock"
      )
    end

    assert Repo.aggregate(Audit, :count) == count
  end

  test "stale, misbound and changed partner snapshots cannot create a race", %{
    scope: scope,
    other: other,
    clock: clock,
    partner: partner
  } do
    path = "#{@url}/#{clock.id}/pair"
    params = snapshot(scope, clock) |> Map.put("partner_id", to_string(partner.id))

    for token <- [
          ApiTokens.clock_snapshot(scope, clock),
          ApiTokens.clock_snapshot(other, partner)
        ] do
      error(
        request(:post, path, Map.put(params, "partner_snapshot_token", token)),
        409,
        "stale_clock"
      )
    end

    {:ok, _} = Clocks.adjust_clock(scope, partner.id, 1)

    error(
      request(
        :post,
        path,
        Map.put(params, "partner_snapshot_token", ApiTokens.clock_snapshot(scope, partner))
      ),
      409,
      "stale_clock"
    )

    assert current(scope, clock.id).racing_group == nil
  end

  test "trigger references and typed flags are validated atomically", %{
    scope: scope,
    clock: clock,
    foreign: foreign
  } do
    {:ok, character} = Characters.create_character(scope.campaign, "456", %{name: "Rook"})

    valid = %{
      "type" => "set_flag",
      "character_id" => to_string(character.id),
      "key" => "debt",
      "flag" => %{"type" => "integer", "value" => 3, "player_visible" => false}
    }

    path = "#{@url}/#{clock.id}"
    attrs = snapshot(scope, clock) |> Map.put("triggers", [valid])
    data = json_response(request(:patch, path, attrs), 200)["data"]
    assert data["triggers"] == [valid]
    assert Repo.get!(AsyncWorlds.Characters.Character, character.id).flags == %{}
    before = Repo.aggregate(Audit, :count)

    for triggers <- [
          [%{"type" => "start_clock", "clock_id" => to_string(foreign.id)}],
          [%{"type" => "start_clock", "clock_id" => to_string(clock.id)}],
          [
            %{
              "type" => "unlock_quest",
              "character_id" => to_string(character.id),
              "quest_id" => "999999"
            }
          ],
          [%{valid | "character_id" => "999999"}],
          [put_in(valid, ["flag", "value"], "3")],
          [%{"type" => "notify_dm", "text" => "bad\u0000text"}],
          ["not an object"],
          %{},
          nil
        ] do
      error(
        request(:patch, path, %{
          "snapshot_token" => data["snapshot_token"],
          "name" => "No",
          "triggers" => triggers
        }),
        422,
        "invalid_parameters"
      )
    end

    assert Repo.aggregate(Audit, :count) == before
    assert current(scope, clock.id).name == clock.name
  end

  test "tick locks block every management write but allow reads", %{
    scope: scope,
    clock: clock,
    partner: partner
  } do
    Repo.update!(Ecto.Changeset.change(scope.campaign, clock_mutations_locked: true))
    path = "#{@url}/#{clock.id}"
    count = Repo.aggregate(Audit, :count)
    error(request(:post, @url, %{"name" => "No", "segments" => 4}), 409, "tick_locked")

    for {method, suffix, params} <- [
          {:patch, "", %{}},
          {:post, "/adjust", %{"delta" => 1}},
          {:post, "/pause", %{}},
          {:post, "/resume", %{}},
          {:post, "/reset", %{}},
          {:post, "/unpair", %{}},
          {:post, "/pair",
           %{
             "partner_id" => to_string(partner.id),
             "partner_snapshot_token" => ApiTokens.clock_snapshot(scope, partner)
           }}
        ] do
      error(
        request(method, path <> suffix, Map.merge(params, snapshot(scope, clock))),
        409,
        "tick_locked"
      )
    end

    assert json_response(request(:get, @url), 200)
    assert json_response(request(:get, path), 200)
    assert Repo.aggregate(Audit, :count) == count
  end

  test "completed clocks reject edits and adjustments until reset", %{scope: scope, clock: clock} do
    {:ok, _} = Clocks.adjust_clock(scope, clock.id, 4)
    {:ok, _} = AsyncWorlds.Clocks.complete_clock(scope.campaign.id, clock.id, "engine")
    clock = current(scope, clock.id)
    path = "#{@url}/#{clock.id}"

    for {method, suffix, params} <- [
          {:patch, "", %{"name" => "No"}},
          {:post, "/adjust", %{"delta" => -1}},
          {:post, "/pause", %{}},
          {:post, "/resume", %{}}
        ] do
      error(
        request(method, path <> suffix, Map.merge(params, snapshot(scope, clock))),
        409,
        "completed"
      )
    end

    reset = json_response(request(:post, path <> "/reset", snapshot(scope, clock)), 200)["data"]
    refute reset["completed"]
    assert reset["filled"] == 0
  end

  test "foreign resources, revoked access and input identities cannot bypass scope", %{
    scope: scope,
    clock: clock,
    foreign: foreign
  } do
    for id <- [foreign.id, "bad", "9223372036854775808", "999999"] do
      error(request(:get, "#{@url}/#{id}"), 404, "not_found")

      error(
        request(:post, "#{@url}/#{id}/adjust", Map.put(snapshot(scope, clock), "delta", 1)),
        404,
        "not_found"
      )
    end

    for key <- ~w(source dm_user_id campaign_id completed racing_group id) do
      error(
        request(:post, @url, %{"name" => "No", "segments" => 4, key => "999"}),
        422,
        "invalid_parameters"
      )
    end

    error(request(:get, @url <> "?dm_user_id=999"), 422, "invalid_parameters")
    assert build_conn() |> get(@url) |> json_response(401)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    error(request(:post, "#{@url}/#{clock.id}/reset", snapshot(scope, clock)), 404, "not_found")
  end

  test "malformed attrs and non-native adjustments are safe validation errors", %{
    scope: scope,
    clock: clock
  } do
    for attrs <- [
          %{"name" => "bad\u0000name", "segments" => 4},
          %{"name" => "Bad", "segments" => 5},
          %{"name" => "Bad", "segments" => 4, "background_rate" => 9_223_372_036_854_775_807},
          %{"name" => "Bad", "segments" => 4, "triggers" => [nil]}
        ] do
      error(request(:post, @url, attrs), 422, "invalid_parameters")
    end

    for delta <- ["1", 1.5, nil, %{}] do
      error(
        request(
          :post,
          "#{@url}/#{clock.id}/adjust",
          Map.put(snapshot(scope, clock), "delta", delta)
        ),
        422,
        "invalid_delta"
      )
    end

    error(request(:post, @url, []), 422, "invalid_parameters")

    error(
      request(
        :post,
        "#{@url}/#{clock.id}/pair",
        snapshot(scope, clock)
        |> Map.put("partner_id", to_string(clock.id))
        |> Map.put("partner_snapshot_token", ApiTokens.clock_snapshot(scope, clock))
      ),
      422,
      "self_link"
    )
  end
end
